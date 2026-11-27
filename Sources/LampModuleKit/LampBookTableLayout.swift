import Foundation

/// Where a book table's cells go, and how its width is shared among its
/// columns.
public enum LampBookTableLayout {
    public struct Placement: Equatable, Sendable {
        public let column: Int
        public let span: Int
        /// Nil for a gap no cell fills, and for a slot a cell above covers.
        public let cell: LampBookTableCell?
        /// The rows a cell reaches down, its own included, as `grid` lays it
        /// out; 1 for a gap, a covered slot, and every placement of a row
        /// laid out alone.
        public let rowSpan: Int
        /// For a slot a cell above reaches down over, the row that cell is
        /// in; `column` and `span` are then that cell's. Nil otherwise.
        public let coveringRow: Int?

        /// Internal, so `Placement.init` stays one public initializer, which
        /// a reference to it without a type can name. Found by Codex.
        init(column: Int, span: Int, cell: LampBookTableCell?, rowSpan: Int, coveringRow: Int?) {
            self.column = column
            self.span = span
            self.cell = cell
            self.rowSpan = rowSpan
            self.coveringRow = coveringRow
        }

        /// A placement in one row: no rows reached below, no cell above.
        public init(column: Int, span: Int, cell: LampBookTableCell?) {
            self.init(column: column, span: span, cell: cell, rowSpan: 1, coveringRow: nil)
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

    /// The table's rows laid out together, so that a cell's `rowSpan` reaches
    /// down over the rows below it.
    ///
    /// Each row is first laid out alone, by `placements(of:columnCount:)`.
    /// A cell then reaches down as many rows as it says, as far as the
    /// table's end, over the gaps and blank cells below it: those become one
    /// covered slot at the cell's columns, the rest of a blank cell's
    /// columns gaps. A blank cell holds nothing but its place (`isBlank`) — the
    /// placeholder a converter leaves under a merged cell (four of the five
    /// overlaps in the bundled books). Any other cell below stops the span
    /// above it, so a span never hides what a cell holds.
    ///
    /// So every cell with words is where `placements(of:columnCount:)` puts
    /// it, in every row, which is why search and the section index, built
    /// from those, find what a reader of the grid shows.
    public static func grid(of rows: [LampBookTableRow], columnCount: Int) -> [[Placement]] {
        var grid: [[Placement]] = []
        var reachedRows: [(row: Int, index: Int, rowSpan: Int)] = []
        walk(rows, columnCount: columnCount) { line in
            grid.append(line)
        } reached: { row, index, rowSpan, _ in
            reachedRows.append((row, index, rowSpan))
        } dropped: { _ in }
        for (row, index, rowSpan) in reachedRows where rowSpan > 1 {
            let placement = grid[row][index]
            grid[row][index] = Placement(
                column: placement.column, span: placement.span, cell: placement.cell,
                rowSpan: rowSpan, coveringRow: nil
            )
        }
        return grid
    }

    /// How many cells `grid` lets reach down fewer rows than their
    /// `rowSpan`: stopped above a cell with words, at the table's end, or
    /// dropped as a blank cell under another's span. Counted row by row,
    /// keeping no row once it is laid out, so a long sparse table costs a
    /// row's placements at a time rather than every slot of it at once.
    /// Found by Codex.
    static func shortenedSpans(of rows: [LampBookTableRow], columnCount: Int) -> Int {
        var shortened = 0
        walk(rows, columnCount: columnCount, line: nil) { _, _, rowSpan, declared in
            if rowSpan < declared { shortened += 1 }
        } dropped: { cell in
            if cell.rowSpan > 1 { shortened += 1 }
        }
        return shortened
    }

    /// The layout `grid` and `shortenedSpans` share: each row's line as it
    /// is laid out, with every placement's `rowSpan` 1; each spanning cell's
    /// place in its line, the rows it reaches and its `rowSpan`, once it
    /// stops; and each blank cell dropped under another's span.
    private static func walk(
        _ rows: [LampBookTableRow],
        columnCount: Int,
        line emit: (([Placement]) -> Void)?,
        reached: (_ row: Int, _ index: Int, _ rowSpan: Int, _ declared: Int) -> Void,
        dropped: (LampBookTableCell) -> Void
    ) {
        let columnCount = bounded(columnCount)
        // A cell reaching down from an earlier row, the last row it may
        // reach, and the last it has.
        struct Reach {
            let row: Int
            let index: Int
            let column: Int
            let span: Int
            let declared: Int
            let last: Int
            var reached: Int
        }
        var reaching: [Reach] = []
        // Per column, for the row being laid out: whether a cell there holds
        // anything, and which span above reaches it (an index into
        // `reaching`, or -1). Looked up by column, so a row costs its
        // columns, not its columns times the spans above it: searched span
        // by span, 64 spans over 20,000 empty rows took ten seconds. Found
        // by Codex.
        var held = [Bool](repeating: false, count: columnCount)
        var owner = [Int](repeating: -1, count: columnCount)
        for (rowIndex, row) in rows.enumerated() {
            let own = placements(of: row, columnCount: columnCount)
            if !reaching.isEmpty {
                for column in held.indices { held[column] = false }
                for placement in own where placement.cell.map({ !isBlank($0) }) ?? false {
                    for column in placement.column..<(placement.column + placement.span) { held[column] = true }
                }
                var continuing: [Reach] = []
                for var reach in reaching {
                    let stopped = reach.last < rowIndex
                        || held[reach.column..<(reach.column + reach.span)].contains(true)
                    if stopped {
                        reached(reach.row, reach.index, reach.reached - reach.row + 1, reach.declared)
                    } else {
                        reach.reached = rowIndex
                        continuing.append(reach)
                    }
                }
                reaching = continuing
            }
            for column in owner.indices { owner[column] = -1 }
            for (index, reach) in reaching.enumerated() {
                for column in reach.column..<(reach.column + reach.span) { owner[column] = index }
            }

            var line: [Placement] = []
            var starting: [Reach] = []
            for placement in own {
                let columns = placement.column..<(placement.column + placement.span)
                guard owner[columns].contains(where: { $0 >= 0 }) else {
                    line.append(placement)
                    if let cell = placement.cell, cell.rowSpan > 1 {
                        // Counted from the rows left, so a span of the
                        // largest integer cannot overflow.
                        let last = rowIndex + min(cell.rowSpan - 1, rows.count - 1 - rowIndex)
                        starting.append(Reach(
                            row: rowIndex, index: line.count - 1,
                            column: placement.column, span: placement.span,
                            declared: cell.rowSpan, last: last, reached: rowIndex
                        ))
                    }
                    continue
                }
                // A gap or a blank cell under a cell above: one covered slot
                // where that cell's columns begin, a gap at each column no
                // cell above covers.
                if let cell = placement.cell { dropped(cell) }
                // Counted, not laid out: no row is kept. Found by Codex.
                guard emit != nil else { continue }
                for column in columns {
                    if owner[column] < 0 {
                        line.append(Placement(column: column, span: 1, cell: nil))
                    } else if reaching[owner[column]].column == column {
                        let reach = reaching[owner[column]]
                        line.append(Placement(
                            column: reach.column, span: reach.span, cell: nil, rowSpan: 1, coveringRow: reach.row
                        ))
                    }
                }
            }
            emit?(line)
            reaching += starting
        }
        for reach in reaching {
            reached(reach.row, reach.index, reach.reached - reach.row + 1, reach.declared)
        }
    }

    /// A cell that holds nothing but its place: no words, and every field
    /// other than its column, spans and blank text at its default. A slot a
    /// cell above can reach over without anything being lost.
    ///
    /// Judged by what it lacks rather than by a list of what to look for:
    /// listed, review found first a footnote marker given as `footnote_refs`
    /// and then a legend's `label` on a cell with no text, each drawn and
    /// each covered. Compared whole, a field added to a cell counts as
    /// content until it is said not to. A header is content too: the bundled
    /// books' placeholders are plain cells. Found by Codex.
    static func isBlank(_ cell: LampBookTableCell) -> Bool {
        // By scalar: a character is whitespace by its first scalar alone, so
        // a space carrying a vowel point (" \u{05B8}") read as blank and its
        // mark was covered. Found by Codex.
        cell.content.text.unicodeScalars.allSatisfy(\.properties.isWhitespace)
            && cell == LampBookTableCell(
                content: LampBookAnnotatedText(text: cell.content.text),
                column: cell.column,
                columnSpan: cell.columnSpan,
                rowSpan: cell.rowSpan
            )
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
