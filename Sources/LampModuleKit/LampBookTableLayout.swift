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

    /// The most columns a table is laid out with. Past it a cell is left
    /// out, as one at a negative column is, and a span is clipped.
    ///
    /// Unbounded, a cell whose `column` plus `colSpan` passed the largest
    /// integer stopped any reader that opened its section, and one merely
    /// very wide made it lay out a gap per empty column — a view each, per
    /// row. 64 is well past real tables: the widest of 691 in the bundled
    /// books reaches 24 columns, the widest of a study Bible's 364 reaches 13.
    /// The inspector warns about a table past it, and the module still builds.
    public static let maximumColumnCount = 64

    /// The table's columns: as many as it declares, or as its widest row
    /// reaches, across every row, up to `maximumColumnCount`. Counted per
    /// row, a row missing its last cells would be laid out narrower than the
    /// rest. A cell that names a column far past the rest widens the table
    /// to reach it, as far as the bound.
    public static func resolvedColumnCount(declared: Int?, rows: [LampBookTableRow]) -> Int {
        // A cell at a negative column is never placed, so it widens nothing.
        let reached = rows
            .flatMap(\.cells)
            .filter { $0.column >= 0 }
            .map { reach(of: $0) }
            .max() ?? 0
        return min(max(declared ?? 0, reached, 1), maximumColumnCount)
    }

    /// The column just past a cell's span, at most the largest integer.
    static func reach(of cell: LampBookTableCell) -> Int {
        let (end, overflow) = cell.column.addingReportingOverflow(max(cell.columnSpan, 1))
        return overflow ? .max : end
    }

    /// A column count a caller passes, kept to the table's bound.
    private static func bounded(_ columnCount: Int) -> Int {
        min(max(columnCount, 0), maximumColumnCount)
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
        let columnCount = bounded(columnCount)
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
        let columnCount = bounded(columnCount)
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
