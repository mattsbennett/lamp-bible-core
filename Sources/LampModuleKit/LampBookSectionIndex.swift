import Foundation

/// What a book section holds that a reader finds their way by: its headings,
/// the passages it cites and the footnotes it cites, each in reading order.
public struct LampBookSectionIndex: Equatable, Sendable {
    public struct Heading: Equatable, Sendable {
        /// The heading's block, among the section's blocks.
        public let blockIndex: Int
        /// As the book gives it, or 2 where it gives none.
        public let level: Int
        public let title: String

        public init(blockIndex: Int, level: Int, title: String) {
            self.blockIndex = blockIndex
            self.level = level
            self.title = title
        }
    }

    /// Every heading, at every level: a dictionary-like book may head its
    /// entries at level 4, so which levels to show is the app's choice.
    public let headings: [Heading]
    /// Each passage cited, once, in the order first cited, every range of an
    /// annotation that cites several.
    public let passages: [LampBookPassage]
    /// Each footnote cited, once, in the order first cited. Their numbers come
    /// from the book (`LampBookFootnoteNumbering`), not from this order.
    public let footnoteIDs: [String]
    /// Every annotated text in the section's blocks, in reading order, for an
    /// app that sets them ahead of time.
    public let annotatedTexts: [LampBookAnnotatedText]

    public init(blocks: [LampBookContentBlock]) {
        var collector = Collector()
        for (index, block) in blocks.enumerated() {
            if block.type == "heading", let content = block.content {
                let title = content.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    collector.headings.append(
                        Heading(blockIndex: index, level: block.level ?? 2, title: title)
                    )
                }
            }
            collector.collect(block)
        }
        headings = collector.headings
        passages = collector.passages
        footnoteIDs = collector.footnoteIDs
        annotatedTexts = collector.texts
    }

    private struct Collector {
        var headings: [Heading] = []
        var passages: [LampBookPassage] = []
        var footnoteIDs: [String] = []
        var texts: [LampBookAnnotatedText] = []
        private var citedPassages: Set<LampBookPassage> = []
        private var citedFootnotes: Set<String> = []

        mutating func collect(_ block: LampBookContentBlock) {
            if let content = block.content { collect(content) }
            if let caption = block.caption?.annotatedText { collect(caption) }
            for item in block.items { collect(item) }
            for row in block.rows {
                for cell in row.cells { collect(cell.content) }
            }
        }

        private mutating func collect(_ item: LampBookListItem) {
            collect(item.content)
            for child in item.children { collect(child) }
        }

        private mutating func collect(_ content: LampBookAnnotatedText) {
            texts.append(content)
            // In the order they appear, whichever kind cites them.
            var citations: [(offset: Int, footnoteID: String?, passages: [LampBookPassage])] = []
            for annotation in content.annotations {
                switch annotation.type {
                case "scripture":
                    citations.append((annotation.start, nil, LampBookPassage.passages(of: annotation)))
                case "footnote":
                    if let id = annotation.data?.footnoteID {
                        citations.append((annotation.start, id, []))
                    }
                default:
                    break
                }
            }
            for reference in content.footnoteReferences {
                citations.append((reference.offset, reference.id, []))
            }
            for citation in citations.enumerated().sorted(by: {
                ($0.element.offset, $0.offset) < ($1.element.offset, $1.offset)
            }).map(\.element) {
                for passage in citation.passages where citedPassages.insert(passage).inserted {
                    passages.append(passage)
                }
                if let id = citation.footnoteID, citedFootnotes.insert(id).inserted {
                    footnoteIDs.append(id)
                }
            }
        }
    }
}
