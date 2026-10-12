import Foundation

/// What a layout will draw from a slide's blocks, and what it will leave out.
///
/// The canvas owns appearance, but *which* blocks reach the slide is knowledge
/// a deck author needs before anything is rendered. Keeping it here means the
/// renderer and the validator cannot drift: the canvas draws this plan, and the
/// validator reports whatever the plan could not place.
public struct LampPresentationSlidePlan: Equatable, Sendable {
    /// The heading, on layouts that show one.
    public var title: LampPresentationBlock?
    /// The line under a title or closing heading.
    public var subtitle: LampPresentationBlock?
    /// Body, scripture, and quotation blocks, in the order the deck wrote them.
    public var prose: [LampPresentationBlock]
    /// Every citation the slide carries.
    public var citations: [LampPresentationBlock]
    /// The two side-by-side blocks of a two-column slide.
    public var columns: [LampPresentationBlock]
    /// The picture, which most layouts place beside their prose.
    public var image: LampPresentationBlock?
    /// A caption, which belongs to the picture and is only drawn with one.
    public var caption: LampPresentationBlock?
    /// Blocks this layout will not draw. A deck that lists any of these has
    /// said something the slide cannot show.
    public var ignored: [LampPresentationBlock]

    /// Everything that reaches the slide.
    public var drawn: [LampPresentationBlock] {
        var result: [LampPresentationBlock] = []
        if let title { result.append(title) }
        if let subtitle { result.append(subtitle) }
        result.append(contentsOf: prose)
        result.append(contentsOf: columns)
        result.append(contentsOf: citations)
        if let image { result.append(image) }
        if let caption { result.append(caption) }
        return result
    }
}

public extension LampPresentationSlide {
    /// How this slide's layout will use its blocks.
    var plan: LampPresentationSlidePlan {
        var remaining = blocks.filter { block in
            block.kind == .image || !block.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        }

        /// Takes the first block of any of `kinds`, in slide order.
        func take(_ kinds: LampPresentationBlockKind...) -> LampPresentationBlock? {
            guard let index = remaining.firstIndex(where: { kinds.contains($0.kind) }) else {
                return nil
            }
            return remaining.remove(at: index)
        }

        /// Takes every block of any of `kinds`, in slide order.
        func takeAll(_ kinds: LampPresentationBlockKind...) -> [LampPresentationBlock] {
            let matching = remaining.filter { kinds.contains($0.kind) }
            remaining.removeAll { kinds.contains($0.kind) }
            return matching
        }

        var plan = LampPresentationSlidePlan(
            title: nil,
            subtitle: nil,
            prose: [],
            citations: [],
            columns: [],
            image: nil,
            caption: nil,
            ignored: []
        )

        switch layout {
        case .title, .closing:
            // Deliberately sparing: a heading and one line beneath it.
            plan.title = take(.title)
            plan.subtitle = take(.subtitle, .body)

        case .titleAndBody:
            plan.title = take(.title)
            plan.prose = takeAll(.subtitle, .body, .scripture, .quotation)
            plan.citations = takeAll(.citation)
            plan.image = take(.image)
            if plan.image != nil { plan.caption = take(.caption) }

        case .blank:
            // Free ordering of supported blocks: everything is drawn, with a
            // heading set like the prose around it.
            plan.prose = takeAll(.title, .subtitle, .body, .scripture, .quotation)
            plan.citations = takeAll(.citation)
            plan.image = take(.image)
            plan.caption = take(.caption)

        case .scripture, .quotation:
            // Scripture and quotation are the same role, so a slide labelled
            // one still draws the other rather than dropping it.
            plan.prose = takeAll(.scripture, .quotation, .body)
            plan.citations = takeAll(.citation)
            plan.image = take(.image)
            if plan.image != nil { plan.caption = take(.caption) }

        case .twoColumn:
            plan.title = take(.title)
            let bodies = takeAll(.body)
            plan.columns = Array(bodies.prefix(2))
            // Anything past the second column has nowhere to go, so it goes
            // back to be reported rather than quietly discarded.
            remaining.append(contentsOf: bodies.dropFirst(2))

        case .image:
            plan.title = take(.title)
            plan.image = take(.image)
            plan.caption = take(.caption)
            plan.citations = takeAll(.citation)
        }

        // Everything placed above was removed as it was taken, so what is left
        // is what the layout will not draw.
        plan.ignored = remaining
        return plan
    }
}
