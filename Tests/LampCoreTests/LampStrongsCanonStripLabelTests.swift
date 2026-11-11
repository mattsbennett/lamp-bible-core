import Foundation
import LampCore
import Testing

/// Placing the standout book's name on the canon strip.
///
/// The case that prompted it: ἔθνος G1484 in the ESV, where Romans is the
/// standout with 29 occurrences and Acts, next to it, has 43 and is the
/// tallest column on the chart. Centred over Romans, the name ran through
/// Acts' bar.
struct LampStrongsCanonStripLabelTests {
    private let column = 10.0
    private let spacing = 2.0

    /// Columns of a given height at given indexes, flat elsewhere.
    private func heights(_ tall: [Int: Double], count: Int = 10) -> [Double] {
        (0..<count).map { tall[$0] ?? 5 }
    }

    @Test func theNameStepsAsideFromATallNeighbour() {
        // Index 4 is the standout at 60; index 5 beside it is 90.
        let placed = LampStrongsCanonStripLabel.place(
            labelWidth: 30, over: 4,
            heights: heights([4: 60, 5: 90]),
            column: column, spacing: spacing, in: 120
        )
        // Centred would span both, so it ends at its own right edge instead,
        // reaching left over the short columns.
        #expect(placed.clearing == 60, "it stands clear of the 90 beside it")
        #expect(placed.x < (column + spacing) * 4 + column / 2, "and has moved left")
    }

    @Test func theNameStaysCentredWhenNothingIsInTheWay() {
        let placed = LampStrongsCanonStripLabel.place(
            labelWidth: 30, over: 4,
            heights: heights([4: 90]),
            column: column, spacing: spacing, in: 120
        )
        #expect(placed.x == (column + spacing) * 4 + column / 2)
        #expect(placed.clearing == 90, "the standout is itself the tallest")
    }

    /// A tie keeps it centred: the name belongs over its own book unless
    /// something is actually in the way.
    @Test func equalNeighboursKeepItCentred() {
        let placed = LampStrongsCanonStripLabel.place(
            labelWidth: 30, over: 4,
            heights: heights([3: 70, 4: 70, 5: 70]),
            column: column, spacing: spacing, in: 120
        )
        #expect(placed.x == (column + spacing) * 4 + column / 2)
        #expect(placed.clearing == 70)
    }

    @Test func theNameStaysOnTheChart() {
        // A long name on the first book: centred would start off the left.
        let first = LampStrongsCanonStripLabel.place(
            labelWidth: 80, over: 0,
            heights: heights([:]), column: column, spacing: spacing, in: 120
        )
        #expect(first.x >= 40, "its left edge is on the chart")

        // And on the last, where it would run off the right.
        let last = LampStrongsCanonStripLabel.place(
            labelWidth: 80, over: 9,
            heights: heights([:]), column: column, spacing: spacing, in: 120
        )
        #expect(last.x <= 80, "its right edge is on the chart")
    }

    /// The clearing is the tallest column the name actually stands over, not
    /// the standout's own height — which is the whole fault being fixed.
    ///
    /// Hemmed in on both sides, so there is no position that avoids the tall
    /// columns: the name has to be lifted clear of a neighbour rather than
    /// of itself.
    @Test func theClearingIsTheTallestColumnUnderTheName() {
        let hemmedIn = LampStrongsCanonStripLabel.place(
            labelWidth: 46, over: 4,
            heights: heights([2: 95, 4: 20, 6: 95]),
            column: column, spacing: spacing, in: 120
        )
        #expect(hemmedIn.clearing == 95, "a neighbour's height counts, not just the standout's")

        // And given a way out, it takes it: the same name with only one tall
        // side stands over the short columns instead.
        let oneSide = LampStrongsCanonStripLabel.place(
            labelWidth: 46, over: 4,
            heights: heights([2: 95, 4: 20]),
            column: column, spacing: spacing, in: 120
        )
        #expect(oneSide.clearing == 20)
        #expect(oneSide.x > (column + spacing) * 4 + column / 2, "moved away from the tall side")
    }

    /// A column the name only grazes still counts: two points of slack, so
    /// the name does not sit a hair over a bar it is touching.
    @Test func aColumnTheNameGrazesCountsAsUnderIt() {
        // The label ends exactly where index 5 begins.
        let labelWidth = 2 * (column / 2 + spacing / 2)
        let placed = LampStrongsCanonStripLabel.place(
            labelWidth: labelWidth, over: 4,
            heights: heights([4: 30, 5: 88]),
            column: column, spacing: spacing, in: 300
        )
        #expect(placed.clearing == 88 || placed.x < (column + spacing) * 4 + column / 2)
    }
}
