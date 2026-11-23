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
    /// a list.
    public enum Part: Hashable, Sendable {
        case block(String)
        case listItem(block: String, index: Int)
    }

    /// The parts in the order they arrive; each inner list arrives together.
    public let units: [[Part]]
    /// Whether the slide's emphasised words light up on a last step of their
    /// own, after everything else has arrived.
    public let emphasisStep: Bool

    private let arrival: [Part: Int]

    public init(units: [[Part]], emphasisStep: Bool) {
        self.units = units
        self.emphasisStep = emphasisStep
        var arrival: [Part: Int] = [:]
        for (index, unit) in units.enumerated() {
            for part in unit where arrival[part] == nil { arrival[part] = index }
        }
        self.arrival = arrival
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
        arrival[.listItem(block: block, index: 1)] != nil
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
        if reveal == .stepwise {
            switch layout {
            case .title, .closing, .titleAndBody, .scripture, .quotation:
                for group in plan.quoteGroups {
                    units.append(contentsOf: Self.revealUnits(of: group))
                }
            case .twoColumn:
                for column in plan.columnGroups.prefix(2) {
                    let parts = column.blocks.map { LampPresentationRevealPlan.Part.block($0.id) }
                    if !parts.isEmpty { units.append(parts) }
                }
            case .blank:
                for block in plan.prose {
                    units.append(contentsOf: Self.revealUnits(of: block))
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
        let hasEmphasis = plan.drawn.contains { block in
            block.kind != .chart && block.kind != .image
                && (block.kind != .caption || captionDrawn)
                && block.drawnRuns(on: layout).contains { $0.mark != nil }
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
        of group: LampPresentationSlidePlan.QuoteGroup
    ) -> [[LampPresentationRevealPlan.Part]] {
        var units = group.quotations.flatMap(revealUnits(of:))
        if let citation = group.citation, !units.isEmpty {
            units[units.count - 1].append(.block(citation.id))
        }
        return units
    }

    private static func revealUnits(of block: LampPresentationBlock) -> [[LampPresentationRevealPlan.Part]] {
        guard block.kind == .body, block.listStyle != nil else { return [[.block(block.id)]] }
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
