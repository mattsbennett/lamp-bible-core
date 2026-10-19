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

    /// Where an image block's `assetPath` can be read from, if anywhere.
    ///
    /// The canvas does not assume a library: a presentation remote renders
    /// slides it received over the wire and has no files at all, so it passes
    /// nothing and gets the placeholder.
    public var assetURL: (LampPresentationBlock) -> URL?

    /// Told how the words were set over the picture behind the slide, for a
    /// tool that reports on what it drew. Called while the slide is drawn.
    public var reportsBackdrop: ((LampPresentationBackdrop.Treatment) -> Void)?

    /// The colours chosen for the words over a picture, in place of the
    /// theme's own.
    private var ink: Ink?

    private struct Ink {
        var text: Color
        var accent: Color
    }

    public init(
        slide: LampPresentationSlide,
        style: LampPresentationSlideStyle,
        compact: Bool = false,
        assetURL: @escaping (LampPresentationBlock) -> URL? = { _ in nil },
        reportsBackdrop: ((LampPresentationBackdrop.Treatment) -> Void)? = nil
    ) {
        self.slide = slide
        self.style = style
        self.compact = compact
        self.assetURL = assetURL
        self.reportsBackdrop = reportsBackdrop
    }

    /// Resolves images against the library the deck was read from.
    public init(
        slide: LampPresentationSlide,
        deck: LampPresentationDeck,
        store: LampPresentationDeckStore,
        compact: Bool = false
    ) {
        self.init(
            slide: slide,
            style: .init(deck: deck),
            compact: compact,
            assetURL: { store.assetURL(for: $0) }
        )
    }

    public init(
        slide: LampPresentationSlide,
        deck: LampPresentationDeck,
        compact: Bool = false
    ) {
        self.init(slide: slide, style: .init(deck: deck), compact: compact)
    }

    private var foreground: Color {
        ink?.text ?? Color(lampDeckHex: style.theme.foregroundColor) ?? .white
    }
    private var accent: Color {
        ink?.accent ?? Color(lampDeckHex: style.theme.accentColor) ?? .orange
    }
    private var background: Color { Color(lampDeckHex: style.theme.backgroundColor) ?? .black }

    public var body: some View {
        GeometryReader { geometry in
            let unit = min(
                geometry.size.width / (style.aspectRatio == .widescreen ? 1_600 : 1_200),
                geometry.size.height / 900
            )
            let pictureURL = plan.background.flatMap(assetURL)
            ZStack {
                background
                if let picture = pictureURL.flatMap(LampPresentationAssetImageCache.swiftUIImage(at:)) {
                    picture
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
                words(
                    unit: unit,
                    over: pictureURL.flatMap { url in
                        LampPresentationAssetImageCache
                            .backdrop(at: url, aspectRatio: style.aspectRatio)
                            .map { _ in url }
                    }
                )
            }
            .clipped()
        }
        .background(background)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    /// Everything on the slide but the picture behind it.
    private func page(unit: CGFloat) -> some View {
        slideContent(unit: unit)
            .padding(.horizontal, 96 * unit)
            .padding(.vertical, 72 * unit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                if let caption = plan.caption, plan.image == nil, plan.background != nil {
                    // A credit, not a caption to read aloud: small, and out of
                    // the way of everything the slide is for.
                    slideBlockText(caption, size: 18 * unit, weight: .regular, alignment: .trailing)
                        .frame(maxWidth: 1_000 * unit, alignment: .trailing)
                        .padding(.trailing, 40 * unit)
                        .padding(.bottom, 26 * unit)
                }
            }
    }

    /// The slide's words, set to be read over the picture at `backdrop` when
    /// there is one that can be read.
    ///
    /// Where the words fall is only known once they are laid out, and their
    /// colour depends on what is under them. So the page is laid out once,
    /// hidden, to find where each block landed; the picture is read under
    /// those places; and the page is drawn again on top in the colours that
    /// reading chose. Colour never changes layout, so the two agree.
    @ViewBuilder
    private func words(unit: CGFloat, over backdrop: URL?) -> some View {
        if let backdrop {
            page(unit: unit)
                .hidden()
                .overlayPreferenceValue(LampSlideTextBounds.self) { anchors in
                    GeometryReader { proxy in
                        let frames = anchors.map { proxy[$0] }
                        if let treatment = LampPresentationAssetImageCache.treatment(
                            for: frames.map { Self.fraction($0, of: proxy.size) },
                            over: backdrop,
                            aspectRatio: style.aspectRatio,
                            theme: style.theme
                        ) {
                            let _ = reportsBackdrop?(treatment)
                            ZStack(alignment: .topLeading) {
                                scrim(treatment, behind: frames, in: proxy.size, unit: unit)
                                inked(treatment).page(unit: unit)
                            }
                        } else {
                            page(unit: unit)
                        }
                    }
                }
        } else {
            page(unit: unit)
        }
    }

    /// This canvas drawing its words in the colours `treatment` chose.
    private func inked(_ treatment: LampPresentationBackdrop.Treatment) -> Self {
        var copy = self
        copy.ink = Ink(
            text: Color(lampDeckHex: treatment.text) ?? foreground,
            accent: Color(lampDeckHex: treatment.accent) ?? accent
        )
        return copy
    }

    /// The picture darkened or lightened behind the words, in bands the width
    /// of the slide that fade out above and below them. The rest of the
    /// picture is left as it is.
    private func scrim(
        _ treatment: LampPresentationBackdrop.Treatment,
        behind frames: [CGRect],
        in size: CGSize,
        unit: CGFloat
    ) -> some View {
        let color = Color(lampDeckHex: treatment.scrim) ?? background
        let feather = 90 * unit
        let bands = treatment.scrimOpacity > 0
            ? Self.bands(around: frames, pad: 36 * unit, feather: feather)
            : []
        return ZStack(alignment: .topLeading) {
            ForEach(Array(bands.enumerated()), id: \.offset) { _, band in
                let height = band.upperBound - band.lowerBound + 2 * feather
                let edge = feather / height
                LinearGradient(
                    stops: [
                        .init(color: color.opacity(0), location: 0),
                        .init(color: color.opacity(treatment.scrimOpacity), location: edge),
                        .init(color: color.opacity(treatment.scrimOpacity), location: 1 - edge),
                        .init(color: color.opacity(0), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: size.width, height: height)
                .offset(y: band.lowerBound - feather)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// The spans down the slide that need the scrim at full strength: every
    /// block's words with `pad` around them, run together where the fades
    /// between them would otherwise overlap.
    static func bands(
        around frames: [CGRect],
        pad: CGFloat,
        feather: CGFloat
    ) -> [ClosedRange<CGFloat>] {
        let spans = frames
            .filter { !$0.isNull && !$0.isEmpty }
            .map { ($0.minY - pad)...($0.maxY + pad) }
            .sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<CGFloat>] = []
        for span in spans {
            if let last = merged.last, span.lowerBound - last.upperBound < 2 * feather {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    /// `rect` as a fraction of `size`, from its top left.
    private static func fraction(_ rect: CGRect, of size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .null }
        return CGRect(
            x: rect.minX / size.width,
            y: rect.minY / size.height,
            width: rect.width / size.width,
            height: rect.height / size.height
        )
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

    /// What this slide's layout will draw. The canvas renders the plan rather
    /// than reaching into `blocks`, so the validator's account of what a layout
    /// leaves out stays true of what actually happens here.
    private var plan: LampPresentationSlidePlan { slide.plan }

    @ViewBuilder
    private func slideContent(unit: CGFloat) -> some View {
        switch slide.layout {
        case .title, .closing:
            VStack(spacing: 24 * unit) {
                if let title = plan.title {
                    slideBlockText(title, size: 76 * unit, weight: .bold, alignment: .center)
                }
                if let subtitle = plan.subtitle {
                    slideBlockText(
                        subtitle,
                        size: 40 * unit,
                        weight: .regular,
                        alignment: .center,
                        color: accent
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .titleAndBody:
            titleAndBodySlide(unit: unit)

        case .scripture, .quotation:
            quotationSlide(unit: unit)

        case .twoColumn:
            twoColumnSlide(unit: unit)

        case .image:
            // A picture behind an image slide is the slide's picture: the
            // heading sits over it at the top rather than above a placeholder.
            let framesPicture = plan.image != nil || plan.background == nil
            VStack(spacing: 22 * unit) {
                if let title = plan.title {
                    slideBlockText(title, size: 48 * unit, weight: .bold)
                }
                if framesPicture {
                    imageArea(unit: unit)
                } else {
                    Spacer(minLength: 0)
                }
                if let caption = plan.caption, framesPicture {
                    slideBlockText(caption, size: 22 * unit, weight: .regular, alignment: .center)
                }
                ForEach(plan.citations) { citation in
                    slideBlockText(
                        citation,
                        size: 20 * unit,
                        weight: .medium,
                        alignment: .center,
                        color: accent
                    )
                }
            }

        case .blank:
            besideImage(unit: unit) {
                VStack(alignment: .leading, spacing: 18 * unit) {
                    ForEach(plan.prose) { block in
                        slideBlockText(block, size: 31 * unit, weight: .regular)
                    }
                    ForEach(plan.citations) { citation in
                        slideBlockText(citation, size: 24 * unit, weight: .medium, color: accent)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    /// A heading, every body block beneath it, and any citations — with a
    /// picture beside the prose when the slide carries one.
    @ViewBuilder
    private func titleAndBodySlide(unit: CGFloat) -> some View {
        // A citation that follows its quotation belongs under it; one that
        // follows nothing belongs at the foot of the slide.
        let attributed = Set(
            plan.quoteGroups.compactMap { group in
                group.quotations.isEmpty ? nil : group.citation?.id
            }
        )
        VStack(alignment: .leading, spacing: 34 * unit) {
            if let title = plan.title {
                slideBlockText(title, size: 58 * unit, weight: .bold)
                Rectangle().fill(accent).frame(width: 120 * unit, height: 6 * unit)
            }
            VStack(alignment: .leading, spacing: 34 * unit) {
                besideImage(unit: unit) {
                    fitted(unit: unit, largest: Self.largestBody, settled: 32, air: 56) { size in
                        let step = size / 32
                        VStack(alignment: .leading, spacing: 24 * unit * step) {
                            ForEach(plan.quoteGroups) { group in
                                VStack(alignment: .leading, spacing: 10 * unit * step) {
                                    ForEach(group.quotations) { body in
                                        slideBlockText(
                                            body,
                                            size: size * unit,
                                            weight: .regular,
                                            stepsDown: false
                                        )
                                    }
                                    if let citation = group.citation,
                                       attributed.contains(citation.id) {
                                        slideBlockText(
                                            citation,
                                            size: Self.citationSize(beside: size) * unit,
                                            weight: .medium,
                                            color: accent,
                                            stepsDown: false
                                        )
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                ForEach(plan.citations.filter { !attributed.contains($0.id) }) { citation in
                    slideBlockText(citation, size: 24 * unit, weight: .medium, color: accent)
                }
            }
            // `.leading` is leading across and centred down, so what little a
            // sparse slide carries sits in the middle of the room left under
            // the heading. Content taller than that space still fills from the
            // top, because the frame grows rather than squeezing it.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        // A sparse slide used to sit against the title with the lower
        // two-thirds empty. The heading stays put so it does not jump between
        // slides; everything under it settles a little above centre, and
        // content taller than the space still fills from the top.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A heading over two columns, each with what it is called, what it says
    /// and where that comes from.
    @ViewBuilder
    private func twoColumnSlide(unit: CGFloat) -> some View {
        let columns = plan.columnGroups
        let first = columns.first
            ?? .init(prose: [LampPresentationBlock(kind: .body, text: "First idea")])
        let second = columns.dropFirst().first
            ?? .init(prose: [LampPresentationBlock(kind: .body, text: "Second idea")])
        VStack(alignment: .leading, spacing: 34 * unit) {
            // The same heading as a title-and-body slide, so it does not change
            // size or lose its rule when the deck moves between the two.
            if let title = plan.title {
                slideBlockText(title, size: 58 * unit, weight: .bold)
                Rectangle().fill(accent).frame(width: 120 * unit, height: 6 * unit)
            }
            // Both columns take one size, so neither reads as the lesser.
            fitted(unit: unit, largest: Self.largestBody, settled: 32, air: 56) { size in
                HStack(alignment: .top, spacing: 50 * unit) {
                    column(first, size: size, unit: unit)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    Rectangle().fill(accent.opacity(0.45)).frame(width: 2 * unit)
                    column(second, size: size, unit: unit)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                // Sized to the columns, so the divider stops where they do
                // rather than running to the foot of the slide.
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// One column: its heading in a heavier weight, then each of its passages
    /// with its citation in the accent colour, as a citation is drawn
    /// everywhere else.
    ///
    /// Two passages under one heading are two things said, so each keeps its
    /// own citation rather than both being credited by one line at the foot.
    ///
    /// A column carrying more than one has to show which citation belongs to
    /// which, and spacing alone did not: a citation sat barely closer to its
    /// own passage than to the next one. Each passage is therefore drawn the
    /// way the quotation layout draws a group — its citation held close
    /// beneath it, a clear gap to the next, and an accent rule down the side
    /// tying the two together. A column carrying one passage keeps the rule
    /// off, which would only cost it width it has no use for.
    private func column(
        _ column: LampPresentationSlidePlan.Column,
        size: CGFloat,
        unit: CGFloat
    ) -> some View {
        let grouped = column.groups.count > 1
        return VStack(alignment: .leading, spacing: (grouped ? 0.62 : 0.44) * size * unit) {
            if let heading = column.heading {
                slideBlockText(heading, size: size * unit, weight: .bold, stepsDown: false)
            }
            ForEach(column.groups) { group in
                VStack(alignment: .leading, spacing: 0.26 * size * unit) {
                    ForEach(group.quotations) { block in
                        slideBlockText(
                            block,
                            size: size * unit,
                            weight: .regular,
                            stepsDown: false
                        )
                    }
                    if let citation = group.citation {
                        slideBlockText(
                            citation,
                            size: Self.citationSize(beside: size) * unit,
                            weight: .medium,
                            color: accent,
                            stepsDown: false
                        )
                    }
                }
                // Lighter than the quotation layout's rule: a column is half
                // the width, and the same 6-unit bar and 34-unit indent would
                // read as a quotation slide squeezed into one side.
                .padding(.leading, grouped ? 22 * unit : 0)
                .overlay(alignment: .leading) {
                    if grouped {
                        RoundedRectangle(cornerRadius: 2 * unit)
                            .fill(accent.opacity(0.8))
                            .frame(width: 4 * unit)
                    }
                }
            }
        }
    }

    /// Every size prose may be set at, on the 900-high design grid.
    ///
    /// Type used only to step down, so a slide with two short lines was set at
    /// the size chosen for a slide with six and left most of itself empty. A
    /// slide now takes the largest of these that fits it.
    static let proseSizes: [CGFloat] = [60, 56, 52, 48, 44, 40, 36, 32, 28, 24, 20, 17, 14.5]

    /// Body type stays under the 58-unit heading above it.
    static let largestBody: CGFloat = 48
    /// A quotation has the slide to itself, so it may be set larger.
    static let largestQuotation: CGFloat = 60

    /// A citation follows its passage down, and only a little way up: it is a
    /// reference, and should read much the same on every slide.
    static func citationSize(beside size: CGFloat) -> CGFloat {
        min(max(size * 0.62, 14), 30)
    }

    /// Draws `content` at the largest prose size that fits the room it is
    /// given, with every block inside it at that one size.
    ///
    /// A size above `settled` must also leave `air` above and below itself.
    /// Without that a slide grows until it touches its heading and its foot,
    /// which is full rather than easy to read.
    private func fitted<Content: View>(
        unit: CGFloat,
        largest: CGFloat,
        settled: CGFloat,
        air: CGFloat,
        @ViewBuilder content: @escaping (_ size: CGFloat) -> Content
    ) -> some View {
        ViewThatFits(in: .vertical) {
            ForEach(Self.proseSizes.filter { $0 <= largest }, id: \.self) { size in
                content(size)
                    // Measured at its natural height, so `ViewThatFits` can
                    // tell which size fits instead of being handed a crushed
                    // one.
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, size > settled ? air * unit : 0)
            }
        }
    }

    /// Every quotation on the slide, then every citation, behind the accent
    /// rule — and beside a picture when there is one, which is what a cover
    /// image wants rather than being pushed under a headline.
    @ViewBuilder
    private func quotationSlide(unit: CGFloat) -> some View {
        besideImage(unit: unit) {
            // Each passage keeps its own rule and its own attribution: two
            // quotations from two places are two things said, not one thing
            // with two sources listed under it.
            fitted(
                unit: unit,
                largest: Self.largestQuotation,
                settled: 34,
                air: 96
            ) { size in
                VStack(alignment: .leading, spacing: 44 * unit * min(size / 34, 1.3)) {
                    ForEach(plan.quoteGroups) { group in
                        quoteGroup(group, size: size, unit: unit)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    /// One quoted passage behind one accent rule, with its citation beneath it.
    private func quoteGroup(
        _ group: LampPresentationSlidePlan.QuoteGroup,
        size: CGFloat,
        unit: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 30 * unit * min(size / 42, 1)) {
            ForEach(group.quotations) { quotation in
                slideBlockText(quotation, size: size * unit, weight: .regular, stepsDown: false)
            }
            if let citation = group.citation {
                slideBlockText(
                    citation,
                    size: Self.citationSize(beside: size) * unit,
                    weight: .medium,
                    color: accent,
                    stepsDown: false
                )
            }
        }
        .padding(.leading, 34 * unit)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3 * unit)
                .fill(accent)
                .frame(width: 6 * unit)
        }
    }

    /// Lays `content` beside the slide's picture, or returns it untouched when
    /// there is none. Images used to draw on image-layout slides alone, which
    /// left every other layout silently dropping one it was given.
    @ViewBuilder
    private func besideImage<Content: View>(
        unit: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if imageBlock == nil {
            content()
        } else {
            HStack(alignment: .center, spacing: 48 * unit) {
                content()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(spacing: 16 * unit) {
                    imageArea(unit: unit)
                    // A caption belongs to the picture, not to the prose, and
                    // these layouts used to drop it along with the image.
                    if let caption = plan.caption {
                        slideBlockText(
                            caption,
                            size: 20 * unit,
                            weight: .regular,
                            alignment: .center
                        )
                    }
                }
                .frame(maxWidth: (style.aspectRatio == .widescreen ? 620 : 440) * unit)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var imageBlock: LampPresentationBlock? { plan.image }

    /// What this block reads as on the slide. A quotation is set in marks, with
    /// ellipses where it starts or ends mid-sentence; everything else is drawn
    /// as the author typed it.
    private func displayText(of block: LampPresentationBlock) -> String {
        guard LampPresentationQuoteTypography.applies(to: block, layout: slide.layout) else {
            return block.text
        }
        return LampPresentationQuoteTypography.displayText(block.text)
    }

    /// The picture itself when it can be read, and an honest placeholder
    /// naming what is missing when it cannot.
    @ViewBuilder
    private func imageArea(unit: CGFloat) -> some View {
        let resolved = imageBlock.flatMap(assetURL).flatMap(
            LampPresentationAssetImageCache.swiftUIImage(at:)
        )

        if let resolved {
            resolved
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 18 * unit))
                .accessibilityLabel(imageBlock?.altText ?? "Image")
        } else {
            RoundedRectangle(cornerRadius: 18 * unit)
                .fill(foreground.opacity(0.09))
                .overlay {
                    VStack(spacing: 10 * unit) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 70 * unit, weight: .light))
                        Text(imageBlock?.altText ?? imageBlock?.assetPath ?? "Image")
                            .font(.system(size: 20 * unit))
                            .lineLimit(1)
                    }
                    .foregroundStyle(foreground.opacity(0.7))
                }
        }
    }

    /// One block's words, which also say where on the slide they landed.
    private func slideBlockText(
        _ block: LampPresentationBlock,
        size: CGFloat,
        weight: Font.Weight,
        alignment: TextAlignment = .leading,
        color: Color? = nil,
        stepsDown: Bool = true
    ) -> some View {
        blockText(
            block,
            size: size,
            weight: weight,
            alignment: alignment,
            color: color,
            stepsDown: stepsDown
        )
        .anchorPreference(key: LampSlideTextBounds.self, value: .bounds) { [$0] }
    }

    @ViewBuilder
    private func blockText(
        _ block: LampPresentationBlock,
        size: CGFloat,
        weight: Font.Weight,
        alignment: TextAlignment,
        color: Color?,
        stepsDown: Bool
    ) -> some View {
        if let listStyle = block.listStyle,
           block.kind == .body,
           !listItems(in: block.text).isEmpty,
           !stepsDown {
            // The slide has already chosen one step for everything on it.
            listRows(
                listItems(in: block.text),
                listStyle: listStyle,
                size: size,
                weight: weight,
                alignment: alignment,
                color: color ?? foreground
            )
            .foregroundStyle(color ?? foreground)
        } else if let listStyle = block.listStyle,
           block.kind == .body,
           !listItems(in: block.text).isEmpty {
            let items = listItems(in: block.text)
            // One size for the whole list, chosen by what fits.
            //
            // Each row used to carry its own `minimumScaleFactor`, so a tight
            // slide squeezed every row independently: beside an ordinary
            // paragraph that kept its size, a list collapsed to little over
            // half of it. Stepping the list as a unit keeps its rows equal to
            // each other and comparable to the prose they sit beside.
            ViewThatFits(in: .vertical) {
                ForEach([1.0, 0.82, 0.68, 0.55, 0.45], id: \.self) { scale in
                    listRows(
                        items,
                        listStyle: listStyle,
                        size: size * scale,
                        weight: weight,
                        alignment: alignment,
                        color: color ?? foreground
                    )
                }
            }
            .foregroundStyle(color ?? foreground)
        } else {
            styledText(
                displayText(of: block),
                size: size,
                weight: weight,
                alignment: alignment,
                color: color ?? foreground,
                scalesToFit: stepsDown
            )
            // A listener hears the words, not the marks Lamp drew around them.
            .accessibilityLabel(block.text)
        }
    }

    /// One list, every row at the same size, with wrapped lines hanging under
    /// the text rather than under the marker.
    private func listRows(
        _ items: [String],
        listStyle: LampPresentationListStyle,
        size: CGFloat,
        weight: Font.Weight,
        alignment: TextAlignment,
        color: Color
    ) -> some View {
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
                        color: color,
                        scalesToFit: false
                    )
                }
            }
        }
        // Measured at its natural height, so `ViewThatFits` can tell which
        // step actually fits instead of being handed a crushed one.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func styledText(
        _ value: String,
        size: CGFloat,
        weight: Font.Weight,
        alignment: TextAlignment,
        color: Color,
        scalesToFit: Bool = true
    ) -> some View {
        Text(value)
            .font(presentationFont(size: size, weight: weight))
            .foregroundStyle(color)
            .multilineTextAlignment(alignment)
            .lineSpacing(size * 0.12)
            .minimumScaleFactor(scalesToFit ? 0.45 : 1)
            // Text the slide has already sized is not cut short in a thumbnail:
            // a truncated passage measures shorter, and the thumbnail would
            // then choose a larger size than the slide it stands for.
            .lineLimit(compact && scalesToFit ? 4 : nil)
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

/// Where each block's words landed on the slide, so a picture behind them is
/// read where it matters and not everywhere.
struct LampSlideTextBounds: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] { [] }

    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
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
