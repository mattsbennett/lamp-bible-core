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
    /// Every block a two-column slide draws in its columns, in slide order.
    public var columns: [LampPresentationBlock]
    /// The picture, which most layouts place beside their prose.
    public var image: LampPresentationBlock?
    /// A caption, which belongs to the picture and is only drawn with one.
    public var caption: LampPresentationBlock?
    /// Blocks this layout will not draw. A deck that lists any of these has
    /// said something the slide cannot show.
    public var ignored: [LampPresentationBlock]

    /// One quoted passage with the citation that attributes it.
    ///
    /// Two quotations from two sources are two things said, not one thing with
    /// two sources listed beneath it, so each is drawn on its own.
    public struct QuoteGroup: Equatable, Sendable, Identifiable {
        public var quotations: [LampPresentationBlock]
        public var citation: LampPresentationBlock?

        public var id: String { quotations.first?.id ?? citation?.id ?? "" }

        public init(quotations: [LampPresentationBlock], citation: LampPresentationBlock?) {
            self.quotations = quotations
            self.citation = citation
        }
    }

    /// `prose` and `citations` read in document order, with each citation
    /// closing the passage it follows.
    public var quoteGroups: [QuoteGroup] = []

    /// One side of a two-column slide: what it is called, what it says, and
    /// where that comes from.
    ///
    /// A column used to be a single body block, so a heading and a reference
    /// could only be typed in as further lines of it and were drawn as body
    /// text like the rest.
    public struct Column: Equatable, Sendable, Identifiable {
        public var heading: LampPresentationBlock?
        public var prose: [LampPresentationBlock]
        public var citation: LampPresentationBlock?

        public var id: String { heading?.id ?? prose.first?.id ?? citation?.id ?? "" }

        /// Everything the column draws, top to bottom.
        public var blocks: [LampPresentationBlock] {
            (heading.map { [$0] } ?? []) + prose + (citation.map { [$0] } ?? [])
        }

        public init(
            heading: LampPresentationBlock? = nil,
            prose: [LampPresentationBlock] = [],
            citation: LampPresentationBlock? = nil
        ) {
            self.heading = heading
            self.prose = prose
            self.citation = citation
        }
    }

    /// The two sides of a two-column slide, in the order the deck wrote them.
    public var columnGroups: [Column] = []

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

extension LampPresentationSlide {
    /// Reads the slide in the order it was written and closes a group at each
    /// citation. Quotations after the last citation form a final, unattributed
    /// group — which is how a slide that quotes without naming a source still
    /// draws its text.
    static func quoteGroups(
        in blocks: [LampPresentationBlock],
        drawnProse: [LampPresentationBlock],
        drawnCitations: [LampPresentationBlock]
    ) -> [LampPresentationSlidePlan.QuoteGroup] {
        let prose = Set(drawnProse.map(\.id))
        let citations = Set(drawnCitations.map(\.id))
        var groups: [LampPresentationSlidePlan.QuoteGroup] = []
        var pending: [LampPresentationBlock] = []
        for block in blocks {
            if prose.contains(block.id) {
                pending.append(block)
            } else if citations.contains(block.id) {
                groups.append(.init(quotations: pending, citation: block))
                pending = []
            }
        }
        if !pending.isEmpty {
            groups.append(.init(quotations: pending, citation: nil))
        }
        return groups
    }
}

extension LampPresentationSlide {
    /// Reads a two-column slide's blocks into columns.
    ///
    /// A `subtitle` opens a column and names it; the prose after it is that
    /// column's, until a citation closes it or the next subtitle opens another.
    /// A slide with no subtitles keeps the older reading, in which every prose
    /// block is a column of its own. Either way a citation attributes the
    /// column it follows.
    static func columnGroups(
        in blocks: [LampPresentationBlock]
    ) -> [LampPresentationSlidePlan.Column] {
        let usesHeadings = blocks.contains { $0.kind == .subtitle }
        var columns: [LampPresentationSlidePlan.Column] = []
        for block in blocks {
            switch block.kind {
            case .subtitle:
                columns.append(.init(heading: block))
            case .body, .scripture, .quotation:
                if usesHeadings, let last = columns.indices.last,
                   columns[last].citation == nil {
                    columns[last].prose.append(block)
                } else {
                    columns.append(.init(prose: [block]))
                }
            case .citation:
                if let last = columns.indices.last,
                   columns[last].citation == nil,
                   !columns[last].prose.isEmpty {
                    columns[last].citation = block
                }
            case .title, .image, .caption:
                break
            }
        }
        return columns
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
            plan.columnGroups = Array(Self.columnGroups(in: remaining).prefix(2))
            // Anything the two columns did not take — a third column, a
            // citation with nothing to attribute — stays behind to be reported
            // rather than quietly discarded.
            let placed = Set(plan.columnGroups.flatMap(\.blocks).map(\.id))
            plan.columns = remaining.filter { placed.contains($0.id) }
            remaining.removeAll { placed.contains($0.id) }

        case .image:
            plan.title = take(.title)
            plan.image = take(.image)
            plan.caption = take(.caption)
            plan.citations = takeAll(.citation)
        }

        // Everything placed above was removed as it was taken, so what is left
        // is what the layout will not draw.
        plan.ignored = remaining
        plan.quoteGroups = Self.quoteGroups(
            in: blocks,
            drawnProse: plan.prose,
            drawnCitations: plan.citations
        )
        return plan
    }
}
