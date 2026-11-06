import Foundation

public enum LampHighlightSearch {
    public static func normalizedColor(_ color: String?) -> String {
        let value = color?.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .uppercased()
        return value?.isEmpty == false ? value! : LampHighlightPalette.fallback.hex
    }

    public static func matchesColor(_ color: String?, in selectedColors: Set<String>?) -> Bool {
        guard let selectedColors, !selectedColors.isEmpty else { return true }
        let normalized = Set(selectedColors.map { normalizedColor($0) })
        return normalized.contains(normalizedColor(color))
    }

    public static func markedSnippet(
        text: String, startOffset: Int, endOffset: Int
    ) -> String {
        guard startOffset >= 0, endOffset > startOffset,
              endOffset <= text.count else { return "<mark>\(text)</mark>" }
        let start = text.index(text.startIndex, offsetBy: startOffset)
        let end = text.index(text.startIndex, offsetBy: endOffset)
        return "<mark>\(text[start..<end])</mark>"
    }
}

extension LampModuleSearch {
    /// A highlight a search found, with its verse's text.
    public struct HighlightHit: Equatable, Sendable {
        /// The set it was found in, as the caller named it.
        public let setID: String
        public let highlight: LampVerseHighlight
        public let text: String
        public let holdsPhrase: Bool
    }

    /// The highlights of `sets` of the colours and books asked for whose
    /// verses hold `query`, at most `limit` of them: each set's newest first,
    /// the room shared between the sets as `sharedEvenly` shares it, and the
    /// sets taking turns in the order given, as the merge gives tied results
    /// theirs. Without a query, the colours and books choose them alone.
    /// `verseTexts` reads a translation's verses, for those the colours and
    /// books leave.
    public static func highlights(
        in sets: [(id: String, highlights: [LampVerseHighlight])],
        query: LampSearchQuery?,
        colors: Set<String>?,
        bookRange: ClosedRange<Int>?,
        limit: Int,
        verseTexts: (_ translationID: String, _ references: Set<Int>) throws -> [Int: String]
    ) rethrows -> [HighlightHit] {
        guard limit > 0 else { return [] }
        let query = query.flatMap { $0.isEmpty || $0.plainText.isEmpty ? nil : $0 }
        let wanted = sets.map { set in
            set.highlights.filter { highlight in
                LampHighlightSearch.matchesColor(highlight.color, in: colors)
                    && bookRange.map { $0.contains(highlight.reference / 1_000_000) } != false
            }.sorted { $0.id > $1.id }
        }
        var texts: [String: [Int: String]] = [:]
        for (translationID, highlights) in Dictionary(grouping: wanted.joined(), by: \.translationID) {
            texts[translationID] = try verseTexts(translationID, Set(highlights.map(\.reference)))
        }
        let found = zip(sets, wanted).map { set, highlights in
            highlights.compactMap { highlight -> HighlightHit? in
                guard let text = texts[highlight.translationID]?[highlight.reference],
                      query?.matches(text) != false else { return nil }
                return HighlightHit(
                    setID: set.id, highlight: highlight, text: text, holdsPhrase: query?.holdsPhrase(text) ?? false
                )
            }
        }
        // Each set's share, then a turn each.
        let kept = zip(found, shares(of: found.map(\.count), limit: limit)).map { Array($0.prefix($1)) }
        var turns: [HighlightHit] = []
        for place in 0..<(kept.map(\.count).max() ?? 0) {
            for share in kept where place < share.count { turns.append(share[place]) }
        }
        return turns
    }
}
