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

    /// The presenter's step through a slide that reveals its content, and
    /// what that slide reveals. Nil everywhere else, which draws the whole
    /// slide. See `revealed(atStep:)`.
    private var revealStep: Int?
    private var revealPlan = LampPresentationRevealPlan.together

    /// A passage's rule drawn beside each item of a list that arrives an
    /// item at a time, so it never runs beside items not yet shown.
    private var listRule: ListRule?

    /// Design units to points on this slide, for the few drawings that size
    /// themselves against the slide's width rather than its prose.
    private var layoutUnit: CGFloat = 1

    /// Whether this is the slide in front of the room, where a picture that
    /// drifts moves. See `presenting(_:)`.
    private var isPresenting = false
    private var presentedSince: Date?

    /// When this slide arrived, which every drifting layer times itself
    /// from, so the picture and its softened copy behind the words move as
    /// one even when the copy first appears at a later click.
    @State private var arrivedAt = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func scaled(_ unit: CGFloat) -> Self {
        var copy = self
        copy.layoutUnit = unit
        return copy
    }

    private struct ListRule {
        var color: Color
        var width: CGFloat
        var inset: CGFloat
        var radius: CGFloat
        /// The gap to the next part of the passage, which the last item's
        /// length runs on into; zero when the list ends the passage.
        var gapAfter: CGFloat
        var opensPassage: Bool
        var closesPassage: Bool
    }

    private struct Ink {
        var text: Color
        var accent: Color
        var highlights: [String: Color]
    }

    public init(
        slide: LampPresentationSlide,
        style: LampPresentationSlideStyle,
        compact: Bool = false,
        assetURL: @escaping (LampPresentationBlock) -> URL? = { _ in nil },
        reportsBackdrop: ((LampPresentationBackdrop.Treatment) -> Void)? = nil
    ) {
        // A comparison's differences are drawn as emphasis, so they are
        // added here, once, for everything that draws from the slide.
        self.slide = slide.markingComparison()
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

    /// This slide as the presenter shows it at `step` of its reveal: the
    /// parts still to come laid out in place and drawn clear, so nothing on
    /// the slide moves as they arrive. Nil draws the whole slide.
    public func revealed(atStep step: Int?) -> Self {
        var copy = self
        copy.revealStep = step
        copy.revealPlan = step == nil ? .together : slide.revealPlan
        return copy
    }

    /// This slide as it is shown to the room, where a picture set to drift
    /// (`LampPresentationImageMotion`) does, timed from when the canvas
    /// appeared, or from `since` where the presenter says when the slide
    /// arrived. Give each slide its own view identity so each drifts from
    /// its own arrival. Everywhere else, and with Reduce Motion on, pictures
    /// are still.
    public func presenting(_ presenting: Bool = true, since: Date? = nil) -> Self {
        var copy = self
        copy.isPresenting = presenting
        copy.presentedSince = since
        return copy
    }

    private func isShown(_ part: LampPresentationRevealPlan.Part) -> Bool {
        revealPlan.isShown(part, atStep: revealStep)
    }

    /// The colours over a picture where there is one, else on the slide's own
    /// ground where it has one, else the theme's.
    private var effectiveInk: Ink? { ink ?? groundInk }

    /// The words' colours on this slide's own ground.
    private var groundInk: Ink? {
        guard let ground = slide.backgroundColor, let chosen = style.theme.ink(on: ground) else { return nil }
        return Ink(
            text: Color(lampDeckHex: chosen.text) ?? .white,
            accent: Color(lampDeckHex: chosen.accent) ?? .orange,
            highlights: chosen.highlights.compactMapValues { Color(lampDeckHex: $0) }
        )
    }

    private var foreground: Color {
        effectiveInk?.text ?? Color(lampDeckHex: style.theme.foregroundColor) ?? .white
    }
    private var accent: Color {
        effectiveInk?.accent ?? Color(lampDeckHex: style.theme.accentColor) ?? .orange
    }
    /// The slide's own ground where it sets one, else the theme's.
    private var background: Color {
        slide.backgroundColor.flatMap { Color(lampDeckHex: $0) }
            ?? Color(lampDeckHex: style.theme.backgroundColor) ?? .black
    }

    /// The colour emphasised words are drawn in: the highlight they name, or
    /// the accent when the theme has none by that name.
    private func color(for mark: LampPresentationTextRun.Mark) -> Color {
        switch mark {
        case .accent:
            return accent
        case .highlight(let name):
            if let ink = effectiveInk { return ink.highlights[name] ?? accent }
            return style.theme.highlights?[name].flatMap { Color(lampDeckHex: $0) } ?? accent
        }
    }

    public var body: some View {
        GeometryReader { geometry in
            let unit = min(
                geometry.size.width / (style.aspectRatio == .widescreen ? 1_600 : 1_200),
                geometry.size.height / 900
            )
            let pictureURL = plan.background.flatMap(assetURL)
            ZStack {
                background
                if let pictureURL, let picture = backdropPicture(at: pictureURL) {
                    focusedFill(picture, at: pictureURL, size: geometry.size)
                }
                words(
                    unit: unit,
                    over: pictureURL.flatMap { url in
                        LampPresentationAssetImageCache
                            .backdrop(at: url, aspectRatio: style.aspectRatio, look: backdropLook)
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
        scaled(unit).slideContent(unit: unit)
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
                .overlayPreferenceValue(LampSlideTextBounds.self) { bounds in
                    GeometryReader { proxy in
                        // Every part's place, shown or still to come, so the
                        // colours chosen hold for the whole reveal; but the
                        // picture is covered only behind words already there.
                        let frames = bounds.map { proxy[$0.anchor] }
                        let regions = frames.map { Self.fraction($0, of: proxy.size) }
                        let sampled = sampled(regions, over: backdrop, in: proxy.size)
                        if let treatment = LampPresentationAssetImageCache.treatment(
                            for: sampled,
                            over: backdrop,
                            aspectRatio: style.aspectRatio,
                            theme: style.theme,
                            look: backdropLook,
                            moments: regions.isEmpty ? 1 : sampled.count / regions.count
                        ) {
                            let _ = reportsBackdrop?(treatment)
                            ZStack(alignment: .topLeading) {
                                scrim(
                                    treatment,
                                    behind: frames,
                                    shown: bounds.map(\.isShown),
                                    in: proxy.size,
                                    unit: unit,
                                    softening: backdropPicture(at: backdrop).map { ($0, backdrop) }
                                )
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
            accent: Color(lampDeckHex: treatment.accent) ?? accent,
            highlights: treatment.highlights.compactMapValues { Color(lampDeckHex: $0) }
        )
        return copy
    }

    /// The picture blurred and then darkened or lightened behind the words,
    /// in fades the width of the slide that run out above and below each
    /// passage. The rest of the picture is left as it is.
    ///
    /// Each block's words are covered as much as they need, which the
    /// treatment gives block by block; blocks whose fades would meet are one
    /// band at the strongest of them (`bands(joining:strengths:within:)`). `softening` is the picture itself, blurred by
    /// `LampPresentationBackdrop.softening` behind every block whether or not
    /// it needs a scrim: fine detail behind a letter hinders reading at any
    /// contrast.
    private func scrim(
        _ treatment: LampPresentationBackdrop.Treatment,
        behind allFrames: [CGRect],
        shown: [Bool],
        in size: CGSize,
        unit: CGFloat,
        softening picture: (image: Image, url: URL)?
    ) -> some View {
        let color = Color(lampDeckHex: treatment.scrim) ?? background
        let allStrengths = treatment.scrimOpacities.count == allFrames.count
            ? treatment.scrimOpacities
            : Array(repeating: treatment.scrimOpacity, count: allFrames.count)
        let kept = allFrames.indices.filter { shown.indices.contains($0) ? shown[$0] : true }
        let frames = kept.map { allFrames[$0] }
        let strengths = kept.map { allStrengths[$0] }
        let joined = Self.bands(
            joining: frames,
            strengths: strengths,
            within: 2 * 36 * unit + 90 * unit
        )
        let shade = Self.profile(
            around: joined.frames,
            strengths: joined.strengths.map(Self.drawnStrength),
            pad: 36 * unit,
            feather: 90 * unit,
            height: size.height
        )
        let reach = Self.profile(
            around: joined.frames,
            strengths: joined.frames.map { _ in 1 },
            pad: 36 * unit,
            feather: 90 * unit,
            height: size.height
        )
        return ZStack(alignment: .topLeading) {
            if let picture, reach.contains(where: { $0.strength > 0 }) {
                // Placed exactly as the picture beneath it is, or the blur
                // would show a second picture slid against the first.
                focusedFill(picture.image, at: picture.url, size: size)
                    .blur(radius: LampPresentationBackdrop.softening * unit, opaque: true)
                    .mask {
                        LinearGradient(
                            stops: reach.map { .init(color: .black.opacity($0.strength), location: $0.location) },
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
            }
            if shade.contains(where: { $0.strength > 0 }) {
                LinearGradient(
                    stops: shade.map { .init(color: color.opacity($0.strength), location: $0.location) },
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// The scrim drawn for a block that the sampler says needs `least`.
    ///
    /// The sampler finds the least scrim that brings the words to 4.5:1 over
    /// 95% of what lies behind them. Drawn at exactly that, words over a busy
    /// painting were legible but no more: the eye still had the picture's
    /// detail to read through, and small lines such as a citation were the
    /// first to suffer. A margin over the least makes the passage
    /// comfortable to read, and only ever raises the contrast the sampler
    /// chose the colours for. A block that needs none is left with none, so
    /// a picture the words read over as it is stays untouched.
    static func drawnStrength(_ least: Double) -> Double {
        guard least > 0 else { return 0 }
        return min(1, least + scrimMargin)
    }

    /// How far above the least the scrim is drawn.
    static let scrimMargin = 0.14

    /// Blocks close enough that their fades would meet, joined into one band
    /// at the strongest of their strengths.
    ///
    /// A title, its rule, a quotation and its citation are read as one
    /// passage. Covered block by block, the picture showed through in
    /// stripes between them, each line at a different depth of shade, and
    /// the small citation lines, which needed the least by their own
    /// measure, were the hardest to read against what showed through. A
    /// block far from the rest, such as a credit at the foot, keeps a band of
    /// its own, and the picture between is still left alone.
    static func bands(
        joining frames: [CGRect],
        strengths: [Double],
        within gap: CGFloat
    ) -> (frames: [CGRect], strengths: [Double]) {
        let blocks = zip(frames, strengths)
            .filter { !$0.0.isNull && !$0.0.isEmpty && $0.1 > 0 }
            .sorted { $0.0.minY < $1.0.minY }
        var joinedFrames: [CGRect] = []
        var joinedStrengths: [Double] = []
        for (frame, strength) in blocks {
            if let last = joinedFrames.last, frame.minY - last.maxY <= gap {
                joinedFrames[joinedFrames.count - 1] = last.union(frame)
                joinedStrengths[joinedStrengths.count - 1] = max(joinedStrengths[joinedStrengths.count - 1], strength)
            } else {
                joinedFrames.append(frame)
                joinedStrengths.append(strength)
            }
        }
        return (joinedFrames, joinedStrengths)
    }

    /// How strongly the scrim lies at each point down a slide `height` tall:
    /// at a block's full strength across its words with `pad` around them,
    /// fading to nothing over `feather` above and below, and the strongest of
    /// any blocks whose fades meet.
    ///
    /// Given as stops for a vertical gradient: every place a fade begins or
    /// ends, and enough between them that the strongest of two overlapping
    /// fades is followed closely.
    static func profile(
        around frames: [CGRect],
        strengths: [Double],
        pad: CGFloat,
        feather: CGFloat,
        height: CGFloat
    ) -> [(location: CGFloat, strength: Double)] {
        guard height > 0 else { return [] }
        let spans = zip(frames, strengths)
            .filter { !$0.0.isNull && !$0.0.isEmpty && $0.1 > 0 }
            .map { (low: $0.0.minY - pad, high: $0.0.maxY + pad, strength: $0.1) }
        guard !spans.isEmpty else { return [(0, 0), (1, 0)] }
        func strength(at y: CGFloat) -> Double {
            spans.reduce(0) { most, span in
                let reach: CGFloat
                if y >= span.low && y <= span.high {
                    reach = 1
                } else if y < span.low {
                    reach = max(0, 1 - (span.low - y) / feather)
                } else {
                    reach = max(0, 1 - (y - span.high) / feather)
                }
                return max(most, span.strength * Double(reach))
            }
        }
        var places = Set<CGFloat>([0, height])
        for span in spans {
            for y in [span.low - feather, span.low, span.high, span.high + feather]
            where y > 0 && y < height {
                places.insert(y)
            }
        }
        // Every so often between, so a crossing of two fades is not cut short.
        let step = feather / 6
        var y = step
        while y < height {
            places.insert(y)
            y += step
        }
        return places.sorted().map { (location: $0 / height, strength: strength(at: $0)) }
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
            // What the room can see so far, and no more.
            guard isShown(.block(block.id)) else { return nil }
            // A map says the places it draws, as they arrive.
            if block.drawnFigure(on: slide.layout) == .map {
                let places = block.mapStops.enumerated()
                    .filter { $0.element.place != nil && isShown(.listItem(block: block.id, index: $0.offset)) }
                    .map(\.element.label)
                return places.isEmpty ? nil : "Map: " + places.joined(separator: ", ")
            }
            // A zoomed timeline says which events are in view.
            let views = block.timelineViews(on: slide.layout)
            if !views.isEmpty {
                let index = revealPlan.view(of: block.id, count: views.count, atStep: revealStep)
                return block.spokenTimeline(views[min(index, views.count - 1)], on: slide.layout)
            }
            if revealPlan.revealsItems(of: block.id) {
                let items = block.listItemRuns.enumerated()
                    .filter { isShown(.listItem(block: block.id, index: $0.offset)) }
                    .map { $0.element.map(\.text).joined() }
                return items.isEmpty ? nil : items.joined(separator: ". ")
            }
            if block.kind == .chart {
                let heading = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let described = block.chart?.spokenDescription ?? "Chart"
                return heading.isEmpty ? described : "\(heading). \(described)"
            }
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
        // Type-erased: one more layout of nested views here took the
        // compiler past its limit on opaque types (a crash, not an error).
        // A `where` binds only the pattern it follows, so each layout
        // carries its own.
        case .title where slide.drawnVariant == .statement, .closing where slide.drawnVariant == .statement:
            AnyView(statementSlide(unit: unit))

        case .title where slide.drawnVariant == .word, .closing where slide.drawnVariant == .word:
            AnyView(wordSlide(unit: unit))

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
                if !plan.quoteGroups.isEmpty {
                    epigraph(unit: unit)
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

    /// The passages under a title or closing heading, each with its citation.
    ///
    /// They are set well below the heading, never larger than
    /// `largestEpigraph`, and centred under it with the heading's rule
    /// between, so the slide keeps the look of a title while the words wait
    /// on screen. A long passage steps down rather than pushing the heading
    /// off the slide.
    private func epigraph(unit: CGFloat) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(accent)
                .frame(width: 120 * unit, height: 6 * unit)
                .padding(.top, 14 * unit)
                .padding(.bottom, 40 * unit)
            fitted(
                unit: unit,
                largest: Self.largestEpigraph,
                settled: Self.largestEpigraph,
                air: 0
            ) { size in
                VStack(spacing: 0.9 * size * unit) {
                    ForEach(plan.quoteGroups) { group in
                        VStack(spacing: 0.3 * size * unit) {
                            ForEach(group.quotations) { passage in
                                slideBlockText(
                                    passage,
                                    size: size * unit,
                                    weight: .regular,
                                    alignment: .center,
                                    stepsDown: false
                                )
                            }
                            if let citation = group.citation {
                                slideBlockText(
                                    citation,
                                    size: Self.citationSize(beside: size) * unit,
                                    weight: .medium,
                                    alignment: .center,
                                    color: accent,
                                    stepsDown: false
                                )
                            }
                        }
                    }
                }
                .frame(maxWidth: 1_200 * unit)
            }
        }
    }

    /// One phrase as large as the slide allows: a heading on its own, to land
    /// a point or open a section, with any line and passages beneath it set
    /// as a title slide sets them.
    private func statementSlide(unit: CGFloat) -> some View {
        VStack(spacing: 28 * unit) {
            if let title = plan.title {
                ViewThatFits(in: .vertical) {
                    ForEach(Self.statementSizes, id: \.self) { size in
                        slideBlockText(title, size: size * unit, weight: .heavy, alignment: .center, stepsDown: false)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 1_320 * unit)
            }
            if let subtitle = plan.subtitle {
                slideBlockText(subtitle, size: 40 * unit, weight: .regular, alignment: .center, color: accent)
            }
            if !plan.quoteGroups.isEmpty {
                epigraph(unit: unit)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A statement's sizes, largest first: the largest that fits is taken.
    static let statementSizes: [CGFloat] = [160, 140, 120, 104, 92, 80, 72]

    /// A Hebrew or Greek word set large, with how it sounds and what it means
    /// beneath it, and any passages under those. In the heading's face, as
    /// the slide's subject.
    private func wordSlide(unit: CGFloat) -> some View {
        VStack(spacing: 22 * unit) {
            if let word = plan.title {
                ViewThatFits(in: .vertical) {
                    ForEach([150, 128, 108, 92, 76] as [CGFloat], id: \.self) { size in
                        slideBlockText(word, size: size * unit, weight: .medium, alignment: .center, stepsDown: false)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 1_320 * unit)
            }
            if let transliteration = plan.subtitle {
                slideBlockText(transliteration, size: 42 * unit, weight: .regular, alignment: .center, color: accent)
                    .italic()
            }
            if let gloss = plan.detail {
                slideBlockText(gloss, size: 34 * unit, weight: .regular, alignment: .center)
                    .frame(maxWidth: 1_100 * unit)
            }
            if !plan.quoteGroups.isEmpty {
                epigraph(unit: unit)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// An epigraph stays under the 40-unit line a title may carry, so it never
    /// competes with the heading it serves.
    static let largestEpigraph: CGFloat = 32

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
        // Two columns at least, so an empty slide still shows its shape.
        let columns = plan.columnGroups.count >= 2
            ? plan.columnGroups
            : plan.columnGroups + [
                .init(prose: [LampPresentationBlock(kind: .body, text: "First idea")]),
                .init(prose: [LampPresentationBlock(kind: .body, text: "Second idea")]),
            ].dropFirst(plan.columnGroups.count)
        VStack(alignment: .leading, spacing: 34 * unit) {
            // The same heading as a title-and-body slide, so it does not change
            // size or lose its rule when the deck moves between the two.
            if let title = plan.title {
                slideBlockText(title, size: 58 * unit, weight: .bold)
                Rectangle().fill(accent).frame(width: 120 * unit, height: 6 * unit)
            }
            // Both columns take one size, so neither reads as the lesser.
            fitted(unit: unit, largest: Self.largestBody, settled: 32, air: 56) { size in
                // Narrower gaps as columns are added, so four still leave
                // each a readable measure.
                HStack(alignment: .top, spacing: (columns.count > 2 ? 34 : 50) * unit) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                        if index > 0 {
                            Rectangle().fill(accent.opacity(0.45)).frame(width: 2 * unit)
                                // Arrives with the column after it: drawn early,
                                // it ran the length of a column not yet shown.
                                .opacity(column.blocks.first.map { isShown(.block($0.id)) } ?? true ? 1 : 0)
                        }
                        self.column(column, size: size, unit: unit)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
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
                            .opacity(group.blocks.first.map { isShown(.block($0.id)) } ?? true ? 1 : 0)
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
        let spacing = 30 * unit * min(size / 42, 1)
        // While a passage arrives a part at a time, the rule is drawn a part
        // at a time with it, each length running on into the gap below so
        // the whole reads as one rule once everything is there. Drawn whole
        // from the start, it ran down through the room kept for parts not
        // yet shown.
        let blocks = group.blocks
        let segmented = revealStep != nil
            && (blocks.count > 1 || blocks.contains { revealPlan.revealsItems(of: $0.id) })
        return VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                let isCitation = block.id == group.citation?.id
                // A timeline's height is the same however many events are
                // shown, so its rule is one length, drawn with the block.
                let itemised = revealPlan.revealsItems(of: block.id)
                    && block.drawnFigure(on: slide.layout) != .timeline
                ruling(
                    itemised && segmented
                        ? ListRule(
                            color: accent,
                            width: 6 * unit,
                            inset: 34 * unit,
                            radius: 3 * unit,
                            gapAfter: index == blocks.count - 1 ? 0 : spacing,
                            opensPassage: index == 0,
                            closesPassage: index == blocks.count - 1
                        )
                        : nil
                )
                .slideBlockText(
                    block,
                    size: (isCitation ? Self.citationSize(beside: size) : size) * unit,
                    weight: isCitation ? .medium : .regular,
                    color: isCitation ? accent : nil,
                    stepsDown: false
                )
                .overlay(alignment: .leading) {
                    // A list arriving an item at a time draws its own lengths.
                    if segmented, !itemised {
                        let last = index == blocks.count - 1
                        LampRuleSegment(
                            color: accent,
                            width: 6 * unit,
                            radius: 3 * unit,
                            roundsTop: index == 0,
                            roundsBottom: last,
                            runsOn: last ? 0 : spacing,
                            inset: 34 * unit,
                            isShown: isShown(.block(block.id))
                        )
                    }
                }
            }
        }
        .padding(.leading, 34 * unit)
        .overlay(alignment: .leading) {
            if !segmented {
                RoundedRectangle(cornerRadius: 3 * unit)
                    .fill(accent)
                    .frame(width: 6 * unit)
                    // A passage of one part still to come keeps its rule
                    // back with it.
                    .opacity(blocks.first.map { isShown(.block($0.id)) } ?? true ? 1 : 0)
            }
        }
    }

    private func ruling(_ rule: ListRule?) -> Self {
        var copy = self
        copy.listRule = rule
        return copy
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

    /// How the picture behind the slide is shown: its focus and its tint.
    private var backdropLook: LampPresentationAssetImageCache.BackdropLook {
        .init(focus: plan.background?.focus, tint: plan.background?.tint, theme: style.theme)
    }

    /// The picture behind the slide, in its tint.
    private func backdropPicture(at url: URL) -> Image? {
        LampPresentationAssetImageCache.swiftUIImage(at: url, tint: plan.background?.tint, theme: style.theme)
    }

    /// `image` filling `size`, cropped around the picture's focus as the
    /// sampler crops it (`LampPresentationFocus.shown`), so the words are
    /// coloured for the part of the picture they are set over.
    private func focusedFill(_ image: Image, at url: URL, size: CGSize) -> some View {
        let picture = LampPresentationAssetImageCache.size(at: url) ?? size
        let shown = LampPresentationFocus.shown(
            in: picture,
            frameRatio: size.height > 0 ? Double(size.width / size.height) : 1,
            focus: plan.background?.focus
        )
        let scale = shown.width > 0 ? size.width / shown.width : 1
        let anchor = LampPresentationImageMotion.driftAnchor(
            in: picture,
            frameRatio: size.height > 0 ? Double(size.width / size.height) : 1,
            focus: plan.background?.focus
        )
        return image
            .resizable()
            .frame(width: picture.width * scale, height: picture.height * scale)
            .offset(x: -shown.minX * scale, y: -shown.minY * scale)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .modifier(drift(of: plan.background, anchor: UnitPoint(x: anchor.x, y: anchor.y)))
            .clipped()
    }

    /// Where to read the picture behind the slide for words at `regions`:
    /// the regions themselves, or for a picture that drifts, what is under
    /// them at each step of the drift, every region at one step and then the
    /// next (`LampPresentationImageMotion.driftViews`), for the treatment to
    /// judge as moments. Read so wherever the slide is drawn,
    /// still or not, so the words keep one colour.
    private func sampled(_ regions: [CGRect], over url: URL, in size: CGSize) -> [CGRect] {
        guard plan.background?.motion == .drift,
              let picture = LampPresentationAssetImageCache.size(at: url) else { return regions }
        let anchor = LampPresentationImageMotion.driftAnchor(
            in: picture,
            frameRatio: size.height > 0 ? Double(size.width / size.height) : 1,
            focus: plan.background?.focus
        )
        let views = regions.map { LampPresentationImageMotion.driftViews(of: $0, anchor: anchor) }
        return (0...LampPresentationImageMotion.driftSteps).flatMap { step in
            views.map { $0.indices.contains(step) ? $0[step] : $0[0] }
        }
    }

    /// `block`'s drift, if it drifts here and now. Drawn as a scale about
    /// `anchor`, inside the picture's own clip, so only its edges go.
    private func drift(of block: LampPresentationBlock?, anchor: UnitPoint) -> LampPresentationDrift {
        LampPresentationDrift(
            since: block?.motion == .drift && isPresenting && !reduceMotion ? presentedSince ?? arrivedAt : nil,
            anchor: anchor
        )
    }

    /// The picture itself when it can be read, and an honest placeholder
    /// naming what is missing when it cannot; or the chart in its place.
    @ViewBuilder
    private func imageArea(unit: CGFloat) -> some View {
        let resolved = imageBlock.flatMap(assetURL).flatMap { url in
            LampPresentationAssetImageCache.swiftUIImage(at: url, tint: imageBlock?.tint, theme: style.theme)
        }

        if let chart = imageBlock, chart.kind == .chart {
            LampPresentationChartView(block: chart, unit: unit, foreground: foreground, accent: accent)
        } else if let resolved {
            // Shown whole, with no focus to keep, so a drift closes in on its
            // middle.
            resolved
                .resizable()
                .scaledToFit()
                .modifier(drift(of: imageBlock, anchor: .center))
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
        .opacity(isShown(.block(block.id)) ? 1 : 0)
        // A list whose items arrive one at a time says where each item is
        // instead (`listRows`), so a picture is not covered behind the ones
        // still to come.
        // Added to, not set: set, an empty answer here replaced the items'.
        .transformAnchorPreference(key: LampSlideTextBounds.self, value: .bounds) { bounds, anchor in
            guard !revealPlan.revealsItems(of: block.id) else { return }
            bounds.append(LampSlideTextBound(anchor: anchor, isShown: isShown(.block(block.id))))
        }
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
        if block.drawnFigure(on: slide.layout) != .none {
            // Type-erased, as the layouts are: a figure's nested views took
            // the compiler past its limit on opaque types.
            if stepsDown {
                // One size for the whole figure, chosen by what fits, as a
                // list steps down as a unit.
                AnyView(ViewThatFits(in: .vertical) {
                    ForEach([1.0, 0.82, 0.68, 0.55, 0.45], id: \.self) { scale in
                        figure(block, size: size * scale, color: color ?? foreground)
                    }
                })
            } else {
                AnyView(figure(block, size: size, color: color ?? foreground))
            }
        } else if let listStyle = block.listStyle,
           block.kind == .body,
           !block.listItemRuns.isEmpty,
           !stepsDown {
            // The slide has already chosen one step for everything on it.
            listRows(
                block.listItemRuns,
                of: block.id,
                listStyle: listStyle,
                size: size,
                weight: weight,
                alignment: alignment,
                color: color ?? foreground
            )
            .foregroundStyle(color ?? foreground)
        } else if let listStyle = block.listStyle,
           block.kind == .body,
           !block.listItemRuns.isEmpty {
            let items = block.listItemRuns
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
                        of: block.id,
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
            // A quotation is set in marks, with ellipses where it starts or
            // ends mid-sentence; everything else is drawn as the author typed
            // it.
            styledText(
                block.drawnRuns(on: slide.layout),
                size: size,
                weight: weight,
                alignment: alignment,
                color: color ?? foreground,
                scalesToFit: stepsDown,
                // A title or subtitle, or a column's heading, which is a
                // subtitle, is set in the heading typeface.
                heading: block.kind == .title || block.kind == .subtitle
            )
            // A listener hears the words, not the marks Lamp drew around them.
            .accessibilityLabel(block.text)
        }
    }

    /// A body block's lines drawn as its figure: a timeline, or a passage's
    /// structure (`LampPresentationFigure`). Each line is a part of its own,
    /// so a reveal brings the figure in an entry at a time.
    @ViewBuilder
    private func figure(_ block: LampPresentationBlock, size: CGFloat, color: Color) -> some View {
        let items = block.listItemRuns
        switch block.drawnFigure(on: slide.layout) {
        case .timeline where !block.timelineViews(on: slide.layout).isEmpty:
            zoomingTimeline(block, size: size, color: color)
        case .timeline:
            timeline(items, of: block.id, size: size, color: color)
        case .chiasm, .parallel:
            structure(items, figure: block.drawnFigure(on: slide.layout), of: block.id, size: size, color: color)
        case .map:
            map(block, size: size)
        case .none:
            EmptyView()
        }
    }

    /// Events evenly along a line, in the order written: the date above in
    /// the accent, a mark on the line, the event below. Each event brings its
    /// own length of the line, so a timeline revealed an event at a time
    /// grows rather than showing its whole span from the start.
    private func timeline(
        _ items: [[LampPresentationTextRun]],
        of blockID: String,
        size: CGFloat,
        color: Color
    ) -> some View {
        let entries = items.map(LampPresentationFigure.timelineEntry)
        // No larger than lets each column's longest word fit its width: the
        // slide only sees a figure too tall, and a word too long for a narrow
        // column was broken mid-word instead ("Solom-on").
        let longest = max(LampPresentationTextMeasure.longestUnbreakable(
            entries.flatMap { $0.date + $0.event }.map(\.text).joined(separator: " ")
        ), 1)
        // The page's width less what shares it: a picture or chart beside
        // the prose (`besideImage`), and a passage's rule.
        let widescreen = style.aspectRatio == .widescreen
        let page: CGFloat = widescreen ? 1_408 : 1_008
        let beside: CGFloat = imageBlock == nil ? 0 : (widescreen ? 620 : 440) + 48
        let rule: CGFloat = slide.layout == .scripture || slide.layout == .quotation ? 34 : 0
        let column = (page - beside - rule) * layoutUnit / CGFloat(max(entries.count, 1))
        let size = min(size, column / (0.52 * CGFloat(longest) + 0.3))
        let line = max(2, size * 0.06)
        // Aligned on the line itself, so each date takes the room it needs
        // and the whole is measured as it is: a fixed room for dates cut a
        // long one short where the slide could not see it to shrink.
        return HStack(alignment: .lampTimelineAxis, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                VStack(spacing: size * 0.3) {
                    // Two lines' room for every date, so the line runs
                    // straight however the dates wrap.
                    styledText(entry.date, size: size * 0.72, weight: .bold, alignment: .center, color: accent, scalesToFit: false)
                        .padding(.horizontal, size * 0.12)
                    ZStack {
                        HStack(spacing: 0) {
                            Rectangle().fill(accent.opacity(index == 0 ? 0 : 0.55)).frame(height: line)
                            // Toward the next event, and only once it has
                            // arrived: ahead of it, the line ran on past the
                            // last event shown and gave away that more came.
                            Rectangle().fill(accent.opacity(index == entries.count - 1 ? 0 : 0.55)).frame(height: line)
                                .opacity(isShown(.listItem(block: blockID, index: index + 1)) ? 1 : 0)
                        }
                        Circle().fill(accent).frame(width: size * 0.36, height: size * 0.36)
                    }
                    .alignmentGuide(.lampTimelineAxis) { $0[VerticalAlignment.center] }
                    styledText(entry.event, size: size * 0.8, weight: .regular, alignment: .center, color: color, scalesToFit: false)
                        .padding(.horizontal, size * 0.12)
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .opacity(isShown(.listItem(block: blockID, index: index)) ? 1 : 0)
                .anchorPreference(key: LampSlideTextBounds.self, value: .bounds) { anchor in
                    revealPlan.revealsItems(of: blockID)
                        ? [LampSlideTextBound(anchor: anchor, isShown: isShown(.listItem(block: blockID, index: index)))]
                        : []
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A timeline shown whole, then a few events at a time
    /// (`LampZoomingTimeline`), its view where the presenter has moved it.
    /// Everywhere else it is drawn as it ends, whole with the stretch
    /// explored marked.
    private func zoomingTimeline(_ block: LampPresentationBlock, size: CGFloat, color: Color) -> AnyView {
        let entries = block.listItemRuns.map(LampPresentationFigure.timelineEntry)
        let views = block.timelineViews(on: slide.layout)
        let span = block.drawnZoom(on: slide.layout)?.span ?? LampPresentationTimelineZoom.defaultSpan
        // Sized as a timeline of `span` events is, which is how many a
        // zoomed-in view shows.
        let longest = max(LampPresentationTextMeasure.longestUnbreakable(
            entries.flatMap { $0.date + $0.event }.map(\.text).joined(separator: " ")
        ), 1)
        let widescreen = style.aspectRatio == .widescreen
        let page: CGFloat = widescreen ? 1_408 : 1_008
        let beside: CGFloat = imageBlock == nil ? 0 : (widescreen ? 620 : 440) + 48
        let rule: CGFloat = slide.layout == .scripture || slide.layout == .quotation ? 34 : 0
        let column = (page - beside - rule) * layoutUnit / CGFloat(span)
        // A canvas with no room draws the timeline as it would unzoomed,
        // which has nothing to divide by.
        guard column > 0, size > 0 else {
            return AnyView(timeline(block.listItemRuns, of: block.id, size: size, color: color))
        }
        let size = min(size, column / (0.52 * CGFloat(longest) + 0.3))
        // A zoomed timeline's emphasis is drawn lit throughout: the whole
        // view, where a slide's last step would light it, does not show its
        // events.
        let lit = revealed(atStep: nil)
        // Room beneath the line for the longest event, measured, at least
        // two lines, so a long one makes the figure taller and the slide
        // chooses a smaller size rather than cutting it short; and the
        // widest date, so the whole view spaces them by what they draw.
        // Measured as drawn: in the deck's face, its emphasis bold, and no
        // smaller than the canvas draws any text.
        let face = style.theme.typeface
        let floor: CGFloat = compact ? 4 : 10
        let eventSize = size * 0.8
        let eventHeight = max(
            entries.map { entry in
                LampPresentationTextMeasure.size(
                    entry.event, family: face, size: eventSize, bold: false,
                    width: column - size * 0.24, lineSpacing: eventSize * 0.12, floor: floor
                ).height
            }.max() ?? 0,
            max(eventSize, floor) * 1.32 * 2
        )
        let dateWidth = (entries.map { entry in
            LampPresentationTextMeasure.size(
                entry.date, family: face, size: size * 0.72, bold: true, floor: floor
            ).width
        }.max() ?? 0) + size * 0.24
        let index = revealPlan.view(of: block.id, count: views.count, atStep: revealStep)
        let view = views[min(index, views.count - 1)]
        let accent = self.accent
        return AnyView(
            LampZoomingTimeline(
                count: entries.count,
                span: span,
                explored: block.exploredEvents(on: slide.layout) ?? 0...(entries.count - 1),
                views: views,
                position: Double(min(index, views.count - 1)),
                size: size,
                eventHeight: eventHeight,
                accent: accent,
                ink: color,
                dateWidth: dateWidth,
                date: { index in
                    AnyView(
                        lit.styledText(entries[index].date, size: size * 0.72, weight: .bold, alignment: .center, color: accent)
                            .padding(.horizontal, size * 0.12)
                    )
                },
                event: { index in
                    AnyView(
                        lit.styledText(entries[index].event, size: size * 0.8, weight: .regular, alignment: .center, color: color)
                            .padding(.horizontal, size * 0.12)
                    )
                }
            )
            // A move along the timeline is a longer way than a part fading
            // in, so it takes longer; with no animation, as with Reduce
            // Motion, it still cuts.
            .transaction { transaction in
                if transaction.animation != nil {
                    transaction.animation = .easeInOut(duration: 0.8)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(block.spokenTimeline(view, on: slide.layout))
        )
    }

    /// A map of the places a body block names (`LampSlideMap`), as tall as
    /// the layout leaves room for under its heading or beside its passage.
    private func map(_ block: LampPresentationBlock, size: CGFloat) -> AnyView {
        let widescreen = style.aspectRatio == .widescreen
        let room: CGFloat = switch slide.layout {
        case .blank: widescreen ? 640 : 760
        case .titleAndBody: widescreen ? 540 : 660
        default: widescreen ? 330 : 420
        }
        let groundHex = slide.backgroundColor ?? style.theme.backgroundColor
        let dark = (LampPresentationColor(hex: groundHex)?.luminance ?? 0) < 0.35
        // The map is its own ground, so its words take the colours that
        // read on that ground, never those chosen for a picture behind the
        // slide, which could be the ground's own colour.
        let mapInk = groundInk?.text ?? Color(lampDeckHex: style.theme.foregroundColor) ?? .white
        let mapAccent = groundInk?.accent ?? Color(lampDeckHex: style.theme.accentColor) ?? .orange
        return AnyView(
            LampSlideMap(
                stops: block.mapStops,
                isShown: { isShown(.listItem(block: block.id, index: $0)) },
                route: block.drawsRoute,
                size: min(size, 30 * layoutUnit * 1.4),
                ground: background,
                groundIsDark: dark,
                ink: mapInk,
                accent: mapAccent,
                // Full height while the slide's words are at their reading
                // size, and shorter with them as the slide steps its type
                // down to fit, so a long heading or a second map is made
                // room for rather than pushed off the slide.
                height: room * layoutUnit * min(1, max(0.35, size / (32 * layoutUnit))),
                font: { presentationFont(size: $0, weight: $1) },
                family: style.theme.typeface
            )
        )
    }

    /// A passage's structure: each line lettered in the accent and stepped
    /// in as the structure sets it, toward the centre of a chiasm, or under
    /// the line it answers.
    private func structure(
        _ items: [[LampPresentationTextRun]],
        figure: LampPresentationFigure,
        of blockID: String,
        size: CGFloat,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: size * 0.32) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, runs in
                HStack(alignment: .firstTextBaseline, spacing: size * 0.4) {
                    Text(figure.letter(at: index, of: items.count))
                        .font(presentationFont(size: size * 0.8, weight: .bold))
                        .foregroundStyle(accent)
                        .frame(minWidth: size * 1.3, alignment: .leading)
                    styledText(runs, size: size, weight: .regular, alignment: .leading, color: color, scalesToFit: false)
                }
                .padding(.leading, CGFloat(figure.indent(at: index, of: items.count)) * size * 1.5)
                .opacity(isShown(.listItem(block: blockID, index: index)) ? 1 : 0)
                // A passage's rule beside the line, a length at a time, as a
                // list arriving an item at a time draws it.
                .overlay(alignment: .leading) {
                    if let rule = listRule {
                        let last = index == items.count - 1
                        LampRuleSegment(
                            color: rule.color,
                            width: rule.width,
                            radius: rule.radius,
                            roundsTop: index == 0 && rule.opensPassage,
                            roundsBottom: last && rule.closesPassage,
                            runsOn: last ? rule.gapAfter : size * 0.32,
                            // The overlay is on the line with its step in
                            // padding, so its leading edge is the passage's.
                            inset: rule.inset,
                            isShown: isShown(.listItem(block: blockID, index: index))
                        )
                    }
                }
                .anchorPreference(key: LampSlideTextBounds.self, value: .bounds) { anchor in
                    revealPlan.revealsItems(of: blockID)
                        ? [LampSlideTextBound(anchor: anchor, isShown: isShown(.listItem(block: blockID, index: index)))]
                        : []
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// One list, every row at the same size, with wrapped lines hanging under
    /// the text rather than under the marker.
    private func listRows(
        _ items: [[LampPresentationTextRun]],
        of blockID: String,
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
                .opacity(isShown(.listItem(block: blockID, index: index)) ? 1 : 0)
                .overlay(alignment: .leading) {
                    if let rule = listRule {
                        let last = index == items.count - 1
                        LampRuleSegment(
                            color: rule.color,
                            width: rule.width,
                            radius: rule.radius,
                            roundsTop: index == 0 && rule.opensPassage,
                            roundsBottom: last && rule.closesPassage,
                            runsOn: last ? rule.gapAfter : size * 0.22,
                            inset: rule.inset,
                            isShown: isShown(.listItem(block: blockID, index: index))
                        )
                    }
                }
                .anchorPreference(key: LampSlideTextBounds.self, value: .bounds) { anchor in
                    revealPlan.revealsItems(of: blockID)
                        ? [LampSlideTextBound(
                            anchor: anchor,
                            isShown: isShown(.listItem(block: blockID, index: index))
                        )]
                        : []
                }
            }
        }
        // Measured at its natural height, so `ViewThatFits` can tell which
        // step actually fits instead of being handed a crushed one.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func styledText(
        _ runs: [LampPresentationTextRun],
        size: CGFloat,
        weight: Font.Weight,
        alignment: TextAlignment,
        color: Color,
        scalesToFit: Bool = true,
        heading: Bool = false
    ) -> some View {
        Text(attributed(runs, size: size, heading: heading))
            .font(presentationFont(size: size, weight: weight, heading: heading))
            .foregroundStyle(color)
            .multilineTextAlignment(alignment)
            .lineSpacing(size * 0.12)
            .minimumScaleFactor(scalesToFit ? 0.45 : 1)
            // Text the slide has already sized is not cut short in a thumbnail:
            // a truncated passage measures shorter, and the thumbnail would
            // then choose a larger size than the slide it stands for.
            .lineLimit(compact && scalesToFit ? 4 : nil)
    }

    /// `runs` as one string, emphasised words bold and in their colour. The
    /// rest takes the font and colour the text view is given.
    private func attributed(
        _ runs: [LampPresentationTextRun],
        size: CGFloat,
        heading: Bool = false
    ) -> AttributedString {
        runs.reduce(into: AttributedString()) { result, run in
            var piece = AttributedString(run.text)
            if let mark = run.mark {
                piece.font = presentationFont(size: size, weight: .bold, heading: heading)
                // Unlit, emphasised words keep their weight and take the plain
                // text colour, so lighting them changes colour and nothing
                // moves. The plain colour by name, not the block's: in a
                // citation, already in the accent, lighting would change
                // nothing.
                piece.foregroundColor = revealPlan.isEmphasisLit(atStep: revealStep)
                    ? color(for: mark)
                    : foreground
            }
            result.append(piece)
        }
    }

    /// The deck's type at `size`: its heading typeface for a heading where it
    /// names one, its typeface otherwise.
    private func presentationFont(size: CGFloat, weight: Font.Weight, heading: Bool = false) -> Font {
        let resolvedSize = max(size, compact ? 4 : 10)
        let headingFace = style.theme.headingTypeface?.trimmingCharacters(in: .whitespacesAndNewlines)
        let face = heading && headingFace?.isEmpty == false ? headingFace : style.theme.typeface
        switch face?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "system-sans":
            return .system(size: resolvedSize, weight: weight)
        case "system-serif":
            return .system(size: resolvedSize, weight: weight, design: .serif)
        // Lamp Rounded by name, for headings in it over a body in another.
        case "system-rounded":
            return .system(size: resolvedSize, weight: weight, design: .rounded)
        case .some(let family) where !family.isEmpty:
            return .custom(family, size: resolvedSize).weight(weight)
        default:
            return .system(size: resolvedSize, weight: weight, design: .rounded)
        }
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
    static var defaultValue: [LampSlideTextBound] { [] }

    static func reduce(value: inout [LampSlideTextBound], nextValue: () -> [LampSlideTextBound]) {
        value.append(contentsOf: nextValue())
    }
}

/// Where one block's words, or one list item's, landed, and whether a reveal
/// has brought them in yet.
struct LampSlideTextBound {
    var anchor: Anchor<CGRect>
    var isShown: Bool
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

/// One length of a passage's rule, beside one part of it, running on into
/// the gap below so the lengths read as one rule once every part is there.
struct LampRuleSegment: View {
    var color: Color
    var width: CGFloat
    var radius: CGFloat
    var roundsTop: Bool
    var roundsBottom: Bool
    /// How far past the part the length runs, into the gap to the next.
    var runsOn: CGFloat
    /// How far left of the part the rule stands.
    var inset: CGFloat
    var isShown: Bool

    var body: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: roundsTop ? radius : 0,
            bottomLeadingRadius: roundsBottom ? radius : 0,
            bottomTrailingRadius: roundsBottom ? radius : 0,
            topTrailingRadius: roundsTop ? radius : 0
        )
        .fill(color)
        .frame(width: width)
        .padding(.bottom, -runsOn)
        .offset(x: -inset)
        .opacity(isShown ? 1 : 0)
    }
}

extension VerticalAlignment {
    /// The line a timeline's events stand on, which their dates above and
    /// events below hang from.
    private enum LampTimelineAxis: AlignmentID {
        static func defaultValue(in dimensions: ViewDimensions) -> CGFloat {
            dimensions[VerticalAlignment.center]
        }
    }

    static let lampTimelineAxis = VerticalAlignment(LampTimelineAxis.self)
}
