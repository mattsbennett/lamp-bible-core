import Foundation

/// How a slide's content arrives while it is presented.
///
/// `together`, the default, shows everything at once. `stepwise` lets the
/// presenter bring in one part of the slide at a time — each verse of a
/// passage, each item of a list, each column of a contrast — so the room
/// reads what is being spoken about rather than ahead of it.
///
/// There is one way for a part to arrive: it fades in where it will sit.
/// Nothing flies in, and nothing already on the slide moves, because the
/// slide is laid out with every part in place and the parts not yet shown
/// are drawn clear.
public enum LampPresentationReveal: String, Codable, CaseIterable, Identifiable, Sendable {
    case together
    case stepwise

    public var id: String { rawValue }

    /// A way this app does not know shows everything at once, so a deck
    /// written by a newer app still opens rather than failing as a whole.
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .together
    }
}

/// How one slide gives way to the next. A dissolve, the default, or a cut.
/// Nothing else is offered: a slide that pushes, spins or zooms draws the eye
/// to the change instead of to what the slide says.
public enum LampPresentationTransition: String, Codable, CaseIterable, Identifiable, Sendable {
    case dissolve
    case cut

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dissolve: "Dissolve"
        case .cut: "Cut"
        }
    }

    /// A transition this app does not know dissolves.
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .dissolve
    }
}

/// Which parts of a slide are shown at each step while it is presented.
///
/// The slide arrives with its first part already shown, so no click lands on
/// an empty slide, and each click brings in the next. Whatever is not one of
/// the parts — a title, a picture, a credit — is there from the start.
/// A step of `nil` means the whole slide, which is what every place but the
/// presenter draws: the editor, thumbnails, the remote's next slide, a PDF.
public struct LampPresentationRevealPlan: Equatable, Sendable {
    /// Something on the slide that can be held back: a block, or one item of
    /// a list. Or where a zoomed timeline's view rests
    /// (`LampPresentationBlock.timelineViews(on:)`): each of its views after
    /// the first is a step, which moves the view rather than bringing
    /// anything in.
    public enum Part: Hashable, Sendable {
        case block(String)
        case listItem(block: String, index: Int)
        case view(block: String, index: Int)
    }

    /// The parts in the order they arrive; each inner list arrives together.
    public let units: [[Part]]
    /// Whether the slide's emphasised words light up on a last step of their
    /// own, after everything else has arrived.
    public let emphasisStep: Bool

    private let arrival: [Part: Int]
    /// The blocks whose items arrive at more than one step.
    private let itemised: Set<String>

    public init(units: [[Part]], emphasisStep: Bool) {
        self.units = units
        self.emphasisStep = emphasisStep
        var arrival: [Part: Int] = [:]
        for (index, unit) in units.enumerated() {
            for part in unit where arrival[part] == nil { arrival[part] = index }
        }
        self.arrival = arrival
        // A map's first place need not be its first line, so its items are
        // counted rather than its second line looked for.
        var steps: [String: Set<Int>] = [:]
        for (part, step) in arrival {
            if case .listItem(let block, _) = part { steps[block, default: []].insert(step) }
        }
        self.itemised = Set(steps.filter { $0.value.count > 1 }.keys)
    }

    public static let together = LampPresentationRevealPlan(units: [], emphasisStep: false)

    /// How many clicks the slide takes after it arrives.
    public var stepCount: Int {
        max(units.count - 1, 0) + (emphasisStep ? 1 : 0)
    }

    /// Whether `part` is shown at `step`. A list item that was not given a
    /// step of its own goes with its block.
    public func isShown(_ part: Part, atStep step: Int?) -> Bool {
        guard let step else { return true }
        if let index = arrival[part] { return index <= step }
        if case .listItem(let block, _) = part, let index = arrival[.block(block)] {
            return index <= step
        }
        return true
    }

    /// Whether `block` is a list whose items arrive one at a time.
    public func revealsItems(of block: String) -> Bool {
        itemised.contains(block)
    }

    /// Which of a zoomed timeline's `count` views `block` rests at, at
    /// `step`: the furthest it has reached. The whole slide, a step of nil,
    /// is the last, which marks the stretch explored.
    public func view(of block: String, count: Int, atStep step: Int?) -> Int {
        guard count > 0 else { return 0 }
        guard let step else { return count - 1 }
        return (0..<count).last { index in
            arrival[.view(block: block, index: index)].map { $0 <= step } ?? false
        } ?? 0
    }

    /// Whether emphasised words are drawn in their colour at `step`. Before
    /// their step they keep their weight, so nothing moves when they light.
    public func isEmphasisLit(atStep step: Int?) -> Bool {
        guard emphasisStep, let step else { return true }
        return step >= stepCount
    }
}

extension LampPresentationSlide {
    /// What this slide reveals and in what order, read from what its layout
    /// draws, so a block the layout leaves out never becomes a step.
    public var revealPlan: LampPresentationRevealPlan {
        let plan = self.plan
        var units: [[LampPresentationRevealPlan.Part]] = []
        // A zoomed timeline moves its view a step at a time whether or not
        // the rest of the slide arrives in parts; the rest is there from the
        // start, since a part not given a step is.
        // Every timeline arrives at its first view, so the first views are
        // one step, and the moves after them a step each.
        if reveal != .stepwise {
            let zoomed = plan.drawn.filter { $0.drawnZoom(on: layout) != nil }
            let moves = zoomed.map { Self.viewUnits(of: $0, on: layout) }
            if !moves.isEmpty {
                units.append(moves.flatMap { $0.first ?? [] })
                units.append(contentsOf: moves.flatMap { $0.dropFirst() })
            }
        }
        if reveal == .stepwise {
            switch layout {
            case .title, .closing, .titleAndBody, .scripture, .quotation:
                for group in plan.quoteGroups {
                    units.append(contentsOf: Self.revealUnits(of: group, on: layout))
                }
            case .twoColumn:
                for column in plan.columnGroups.prefix(Self.mostColumns) {
                    let parts = column.blocks.map { LampPresentationRevealPlan.Part.block($0.id) }
                    if !parts.isEmpty { units.append(parts) }
                }
            case .blank:
                for block in plan.prose {
                    units.append(contentsOf: Self.revealUnits(of: block, on: layout))
                }
            case .image:
                break
            }
        }
        // Emphasis that actually draws: an entry whose words are no longer
        // in the text marks nothing, and a step for it would be a click that
        // changes nothing.
        // Only words drawn with their emphasis can light. A chart's heading
        // is drawn without it, and a caption is drawn only beside or over a
        // picture, or on an image slide.
        let captionDrawn = layout == .image || plan.image != nil || plan.background != nil
        // With what a comparison marks, which lights as emphasis does.
        let compared = markingComparison()
        let comparedBlocks = Dictionary(
            compared.blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        // Nor a zoomed timeline's, whose events the whole view, where a
        // last step would light them, does not show.
        let hasEmphasis = plan.drawn.map { comparedBlocks[$0.id] ?? $0 }.contains { block in
            guard block.drawnZoom(on: layout) == nil else { return false }
            return block.kind != .chart && block.kind != .image
                && (block.kind != .caption || captionDrawn)
                && block.drawnMarkedRuns(on: layout).contains { $0.mark != nil }
        }
        return LampPresentationRevealPlan(
            units: units.count > 1 ? units : [],
            emphasisStep: revealsEmphasis == true && hasEmphasis
        )
    }

    /// A passage arrives a block at a time, a list an item at a time, and its
    /// citation with its last part. With the first, it waited at the foot of
    /// the room kept for the rest, apart from the words it credits. A
    /// citation with no passage to go with is there from the start.
    private static func revealUnits(
        of group: LampPresentationSlidePlan.QuoteGroup,
        on layout: LampPresentationSlideLayout
    ) -> [[LampPresentationRevealPlan.Part]] {
        var units = group.quotations.flatMap { revealUnits(of: $0, on: layout) }
        if let citation = group.citation, !units.isEmpty {
            units[units.count - 1].append(.block(citation.id))
        }
        return units
    }

    private static func revealUnits(
        of block: LampPresentationBlock,
        on layout: LampPresentationSlideLayout
    ) -> [[LampPresentationRevealPlan.Part]] {
        // A zoomed timeline arrives whole, and then moves its view.
        if block.drawnZoom(on: layout) != nil {
            var units = viewUnits(of: block, on: layout)
            units[0].insert(.block(block.id), at: 0)
            return units
        }
        // A map: its places, one at a time; a line that names no place Lamp
        // can draw is left off, and takes no click of its own.
        if block.drawnFigure(on: layout) == .map {
            let found = block.mapStops.enumerated().filter { $0.element.place != nil }.map(\.offset)
            guard found.count > 1 else { return [[.block(block.id)]] }
            return found.enumerated().map { order, index in
                order == 0
                    ? [.block(block.id), .listItem(block: block.id, index: index)]
                    : [.listItem(block: block.id, index: index)]
            }
        }
        // A list, or a figure: a timeline's events, a structure's lines.
        guard block.kind == .body, block.listStyle != nil || block.drawnFigure != .none else {
            return [[.block(block.id)]]
        }
        let count = block.listItemRuns.count
        guard count > 1 else { return [[.block(block.id)]] }
        return (0..<count).map { index in
            // The list itself arrives with its first item; each later item on
            // its own.
            index == 0
                ? [.block(block.id), .listItem(block: block.id, index: 0)]
                : [.listItem(block: block.id, index: index)]
        }
    }
}

extension LampPresentationSlide {
    /// A zoomed timeline's views, a step each, the first arriving with the
    /// block.
    fileprivate static func viewUnits(
        of block: LampPresentationBlock,
        on layout: LampPresentationSlideLayout
    ) -> [[LampPresentationRevealPlan.Part]] {
        block.timelineViews(on: layout).indices.map { [.view(block: block.id, index: $0)] }
    }
}

/// Where a presenter is in a deck: which slide, and how far into its reveal.
///
/// One rule for every presenter, so the Mac, the phone and the remote agree on
/// what a click does. Forward brings in the next part, or the next slide once
/// this one is complete. Back takes the last part away, or returns to the
/// previous slide as it was left, complete. A jump lands on a slide's start.
public struct LampPresentationPosition: Equatable, Sendable {
    public var slide: Int
    public var step: Int

    public init(slide: Int = 0, step: Int = 0) {
        self.slide = slide
        self.step = step
    }

    /// One click forward through `slides`, the ones being shown; nil at the
    /// end of the deck.
    public func advanced(in slides: [LampPresentationSlide]) -> Self? {
        guard slides.indices.contains(slide) else { return nil }
        if step < slides[slide].revealPlan.stepCount {
            return Self(slide: slide, step: step + 1)
        }
        return slide + 1 < slides.count ? Self(slide: slide + 1, step: 0) : nil
    }

    /// One click back; nil at the start of the deck.
    public func retreated(in slides: [LampPresentationSlide]) -> Self? {
        if step > 0 { return Self(slide: slide, step: step - 1) }
        guard slide > 0, slides.indices.contains(slide - 1) else { return nil }
        return Self(slide: slide - 1, step: slides[slide - 1].revealPlan.stepCount)
    }
}
