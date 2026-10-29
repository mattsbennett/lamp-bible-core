import Foundation

/// Where a book table's cells go, and how its width is shared among its
/// columns.
public enum LampBookTableLayout {
    public struct Placement: Equatable, Sendable {
        public let column: Int
        public let span: Int
        /// Nil for a gap no cell fills.
        public let cell: LampBookTableCell?

        public init(column: Int, span: Int, cell: LampBookTableCell?) {
            self.column = column
            self.span = span
            self.cell = cell
        }
    }

    /// The table's columns: as many as it declares, or as its widest row
    /// reaches, across every row. Counted per row, a row missing its last
    /// cells would be laid out narrower than the rest. A cell that names a
    /// column far past the rest widens the table to reach it.
    public static func resolvedColumnCount(declared: Int?, rows: [LampBookTableRow]) -> Int {
        let reached = rows
            .flatMap(\.cells)
            .map { $0.column + max($0.columnSpan, 1) }
            .max() ?? 0
        return max(declared ?? 0, reached, 1)
    }

    /// A row's cells at the columns they name, with a gap wherever no cell
    /// does.
    ///
    /// By column rather than in turn, so that a row missing a cell keeps the
    /// rest under their headings. That depends on each cell keeping its true
    /// `column`: renumbered in turn, a row missing a cell would shift again.
    /// A cell outside the table is left out, which with the count from
    /// `resolvedColumnCount` means only one naming a negative column; of two
    /// cells naming the same column the first is kept.
    public static func placements(of row: LampBookTableRow, columnCount: Int) -> [Placement] {
        var cells: [Int: LampBookTableCell] = [:]
        for cell in row.cells where cell.column >= 0 && cell.column < columnCount && cells[cell.column] == nil {
            cells[cell.column] = cell
        }
        var placements: [Placement] = []
        var column = 0
        while column < columnCount {
            if let cell = cells[column] {
                let span = min(max(cell.columnSpan, 1), columnCount - column)
                placements.append(Placement(column: column, span: span, cell: cell))
                column += span
            } else {
                placements.append(Placement(column: column, span: 1, cell: nil))
                column += 1
            }
        }
        return placements
    }

    /// Each column's share of the table's width, summing to 1, by the longest
    /// text it holds, so that a column of single terms beside one of
    /// definitions doesn't take half the table. No column falls below
    /// 0.6 ÷ the column count.
    ///
    /// Shares rather than widths: one app scales them to the reading width,
    /// another to a wider table that scrolls. Widening a column to fit its
    /// longest word takes the app's font, so is the app's to do.
    public static func columnWeights(rows: [LampBookTableRow], columnCount: Int) -> [Double] {
        guard columnCount > 0 else { return [] }
        var lengths = Array(repeating: 0.0, count: columnCount)
        for row in rows {
            for cell in row.cells
            where cell.columnSpan == 1 && !cell.isHeader && lengths.indices.contains(cell.column) {
                lengths[cell.column] = max(
                    lengths[cell.column],
                    Double(min(cell.content.text.count, 240))
                )
            }
        }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return Array(repeating: 1 / Double(columnCount), count: columnCount) }
        let floor = 0.6 / Double(columnCount)
        let raised = lengths.map { max($0 / total, floor) }
        let sum = raised.reduce(0, +)
        return raised.map { $0 / sum }
    }
}
