import LampCore
import SwiftUI

/// A chart block, in the slide's colours, at any size.
///
/// Bars run across, because their labels are book names and English words,
/// which read across rather than up. Columns stand in canonical order, so
/// where a word gathers shows as a shape. A grid shades each book's chapters,
/// and a share is a ring of the whole, each slice named beside it.
///
/// Bars and columns put the accent on a book or section holding more than its
/// share of the words predicts, and draw one holding notably fewer fainter
/// than the rest; a key says so whenever either appears, since colour alone
/// tells a room nothing. The grid and the share have one hue that deepens with
/// the count, because their colour is the count: a palette of hues would have
/// to be told apart, and the numbers are printed beside the ring anyway.
struct LampPresentationChartView: View {
    let block: LampPresentationBlock
    let unit: CGFloat
    let foreground: Color
    let accent: Color

    var body: some View {
        let heading = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 18 * unit) {
            if !heading.isEmpty {
                Text(heading)
                    .font(.system(size: 30 * unit, weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(foreground)
            }
            if let chart = block.chart, let values = chart.values, !values.isEmpty {
                switch chart.drawnStyle {
                case .bars: bars(chart, values)
                case .columns: columns(chart, values)
                case .grid: grid(chart, values)
                case .share: share(chart, values)
                }
            } else {
                placeholder
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(block.chart?.spokenDescription ?? "Chart")
    }

    // MARK: - Bars

    /// The bars from the top of the room they are given, each value printed
    /// at its bar's end, and the key directly beneath them.
    private func bars(_ chart: LampPresentationChart, _ values: [LampPresentationChart.Value]) -> some View {
        let standings = Set(values.compactMap(\.standing))
        let keyHeight = standings.isEmpty ? 0 : 44 * unit
        return GeometryReader { geometry in
            let row = min(64 * unit, max(geometry.size.height - keyHeight, 0) / CGFloat(values.count))
            let type = max(min(row * 0.48, 26 * unit), 11 * unit)
            let gap = 14 * unit
            let labelWidth = geometry.size.width * 0.3
            let room = max(geometry.size.width - labelWidth - type * 3.6 - 2 * gap, 0)
            let largest = values.map(\.value).max() ?? 0
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    HStack(spacing: gap) {
                        Text(value.label)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(width: labelWidth, alignment: .trailing)
                        RoundedRectangle(cornerRadius: 4 * unit)
                            .fill(color(for: value.standing))
                            .frame(width: length(of: value, in: room, largest: largest), height: row * 0.62)
                        Text(chart.formatted(value.value))
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .font(.system(size: type))
                    .foregroundStyle(foreground)
                    .frame(height: row)
                }
                key(standings)
                    .frame(height: keyHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// A bar's length against the largest. A notable zero keeps a stub in its
    /// colour, so "fewer than its size predicts" is seen where it is said.
    private func length(of value: LampPresentationChart.Value, in room: CGFloat, largest: Double) -> CGFloat {
        guard largest > 0, value.value > 0 else { return value.standing == nil ? 0 : 4 * unit }
        return max(room * value.value / largest, 4 * unit)
    }

    // MARK: - Columns

    /// A column a book, in canonical order. Past a dozen or so the columns
    /// are too narrow for names or figures, so the books are named by their
    /// abbreviations, turned to read upward, and the heights carry the rest.
    private func columns(_ chart: LampPresentationChart, _ values: [LampPresentationChart.Value]) -> some View {
        let standings = Set(values.compactMap(\.standing))
        let keyHeight = standings.isEmpty ? 0 : 44 * unit
        let crowded = values.count > 14
        return GeometryReader { geometry in
            let slot = geometry.size.width / CGFloat(values.count)
            let labelHeight = crowded ? 72 * unit : 34 * unit
            let figureHeight = crowded ? 0 : 30 * unit
            let plot = max(geometry.size.height - keyHeight - labelHeight - figureHeight - 8 * unit, 0)
            let largest = values.map(\.value).max() ?? 0
            let type = min(crowded ? 15 * unit : 18 * unit, slot * (crowded ? 0.7 : 0.3))
            VStack(spacing: 0) {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                        VStack(spacing: 6 * unit) {
                            if !crowded {
                                Text(chart.formatted(value.value))
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)
                            }
                            RoundedRectangle(cornerRadius: 3 * unit)
                                .fill(color(for: value.standing))
                                .frame(
                                    width: slot * 0.72,
                                    height: largest > 0 && value.value > 0
                                        ? max(plot * value.value / largest, 3 * unit)
                                        : (value.standing == nil ? 0 : 3 * unit)
                                )
                        }
                        .frame(width: slot, height: plot + figureHeight, alignment: .bottom)
                    }
                }
                Rectangle()
                    .fill(foreground.opacity(0.35))
                    .frame(height: max(unit, 1))
                HStack(spacing: 0) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                        if crowded {
                            Text(LampPresentationChart.abbreviated(value.label))
                                .lineLimit(1)
                                .fixedSize()
                                .rotationEffect(.degrees(-90))
                                .frame(width: slot, height: labelHeight)
                        } else {
                            Text(value.label)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .minimumScaleFactor(0.5)
                                .frame(width: slot, height: labelHeight, alignment: .top)
                        }
                    }
                }
                .padding(.top, 6 * unit)
                key(standings)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: keyHeight)
            }
            .font(.system(size: type))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - Grid

    /// A row a book, a cell a chapter, each shaded by its count against the
    /// fullest chapter in the grid, with a stepped key beneath. Steps, not a
    /// gradient: an exported PDF paints a gradient's transparency flat.
    private func grid(_ chart: LampPresentationChart, _ values: [LampPresentationChart.Value]) -> some View {
        let keyHeight = 44 * unit
        let longest = max(values.map { $0.chapters?.count ?? 0 }.max() ?? 0, 1)
        let largest = values.flatMap { $0.chapters ?? [] }.max() ?? 0
        return GeometryReader { geometry in
            let row = min(40 * unit, max(geometry.size.height - keyHeight, 0) / CGFloat(values.count))
            let labelWidth = min(geometry.size.width * 0.2, 220 * unit)
            let gap = 12 * unit
            let cell = max(geometry.size.width - labelWidth - gap, 0) / CGFloat(longest)
            let inset = min(cell, row) * 0.08
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    HStack(spacing: gap) {
                        Text(value.label)
                            .font(.system(size: max(min(row * 0.55, 22 * unit), 9 * unit)))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .frame(width: labelWidth, alignment: .trailing)
                        HStack(spacing: 0) {
                            ForEach(Array((value.chapters ?? []).enumerated()), id: \.offset) { _, count in
                                RoundedRectangle(cornerRadius: min(cell, row) * 0.15)
                                    .fill(shade(count, of: largest))
                                    .padding(inset)
                                    .frame(width: cell, height: row)
                            }
                        }
                    }
                    .frame(height: row)
                }
                gridKey(chart, largest: largest)
                    .frame(height: keyHeight)
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func shade(_ count: Double, of largest: Double) -> Color {
        guard largest > 0, count > 0 else { return foreground.opacity(0.07) }
        return accent.opacity(0.22 + 0.78 * count / largest)
    }

    private func gridKey(_ chart: LampPresentationChart, largest: Double) -> some View {
        HStack(spacing: 8 * unit) {
            Text("0")
            ForEach(0..<6, id: \.self) { step in
                RoundedRectangle(cornerRadius: 3 * unit)
                    .fill(shade(largest * Double(step) / 5, of: largest))
                    .frame(width: 22 * unit, height: 18 * unit)
            }
            Text(chart.formatted(largest))
                .monospacedDigit()
            Text(chart.measure == .occurrences ? "in a chapter" : "per 1,000 words in a chapter")
                .padding(.leading, 8 * unit)
        }
        .font(.system(size: 18 * unit))
        .foregroundStyle(foreground.opacity(0.8))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Share

    /// A ring of the whole, largest slice first from twelve o'clock, each
    /// named beside it with its count and share. Labels on a side are pushed
    /// apart where small slices would put them on top of one another.
    private func share(_ chart: LampPresentationChart, _ values: [LampPresentationChart.Value]) -> some View {
        let total = values.reduce(0) { $0 + max($1.value, 0) }
        let largest = values.map(\.value).max() ?? 0
        return Canvas { context, size in
            guard total > 0 else { return }
            let radius = min(size.height * 0.42, size.width * 0.24)
            let hole = radius * 0.6
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let gap = Angle.degrees(values.count > 1 ? 0.8 : 0)
            let type = 18 * unit
            let line = type * 2.6

            var start = Angle.degrees(-90)
            var labels: [(middle: Angle, text: Text, figures: Text)] = []
            for value in values where value.value > 0 {
                let sweep = Angle.degrees(360 * value.value / total)
                var slice = Path()
                slice.addArc(center: centre, radius: radius, startAngle: start + gap, endAngle: start + sweep - gap, clockwise: false)
                slice.addArc(center: centre, radius: hole, startAngle: start + sweep - gap, endAngle: start + gap, clockwise: true)
                slice.closeSubpath()
                context.fill(slice, with: .color(accent.opacity(0.3 + 0.7 * value.value / largest)))
                let percent = Int((value.value * 100 / total).rounded())
                labels.append((
                    start + sweep / 2,
                    Text(value.label).font(.system(size: type, weight: .medium)),
                    Text("\(chart.formatted(value.value)) · \(percent)%").font(.system(size: type * 0.85)).monospacedDigit()
                ))
                start += sweep
            }

            context.draw(
                Text(chart.formatted(total)).font(.system(size: hole * 0.42, weight: .semibold)).monospacedDigit(),
                at: CGPoint(x: centre.x, y: centre.y - hole * 0.08)
            )
            context.draw(
                Text("occurrences").font(.system(size: hole * 0.16)),
                at: CGPoint(x: centre.x, y: centre.y + hole * 0.3)
            )

            for right in [true, false] {
                var placed = labels.enumerated()
                    .filter { (cos($0.element.middle.radians) >= 0) == right }
                    .map { (index: $0.offset, y: centre.y + (radius + 24 * unit) * sin($0.element.middle.radians)) }
                    .sorted { $0.y < $1.y }
                for index in placed.indices.dropFirst() where placed[index].y < placed[index - 1].y + line {
                    placed[index].y = placed[index - 1].y + line
                }
                if let last = placed.last, last.y > size.height - line / 2 {
                    let lift = last.y - (size.height - line / 2)
                    for index in placed.indices { placed[index].y -= lift }
                }
                for entry in placed {
                    let label = labels[entry.index]
                    let edge = CGPoint(
                        x: centre.x + (radius + 4 * unit) * cos(label.middle.radians),
                        y: centre.y + (radius + 4 * unit) * sin(label.middle.radians)
                    )
                    let x = centre.x + (right ? 1 : -1) * (radius + 40 * unit)
                    var leader = Path()
                    leader.move(to: edge)
                    leader.addLine(to: CGPoint(x: x - (right ? 8 : -8) * unit, y: entry.y))
                    context.stroke(leader, with: .color(foreground.opacity(0.4)), lineWidth: max(unit, 1))
                    let anchor: UnitPoint = right ? .leading : .trailing
                    context.draw(label.text, at: CGPoint(x: x, y: entry.y - type * 0.55), anchor: anchor)
                    context.draw(label.figures, at: CGPoint(x: x, y: entry.y + type * 0.6), anchor: anchor)
                }
            }
        }
        .foregroundStyle(foreground)
    }

    // MARK: - Keys and colour

    @ViewBuilder
    private func key(_ standings: Set<LampStrongsAnalysis.Expectation>) -> some View {
        if !standings.isEmpty {
            HStack(spacing: 28 * unit) {
                if standings.contains(.more) { swatch(.more, "More than its size predicts") }
                if standings.contains(.fewer) { swatch(.fewer, "Fewer than its size predicts") }
            }
            .font(.system(size: 18 * unit))
            .foregroundStyle(foreground.opacity(0.8))
        }
    }

    private func swatch(_ standing: LampStrongsAnalysis.Expectation, _ label: String) -> some View {
        HStack(spacing: 8 * unit) {
            RoundedRectangle(cornerRadius: 3 * unit)
                .fill(color(for: standing))
                .frame(width: 18 * unit, height: 18 * unit)
            Text(label)
        }
    }

    private func color(for standing: LampStrongsAnalysis.Expectation?) -> Color {
        switch standing {
        case .more: accent
        case .fewer: foreground.opacity(0.28)
        default: foreground.opacity(0.62)
        }
    }

    /// A chart with no values yet says what it will chart, as a missing
    /// picture names the file it is waiting for.
    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 18 * unit)
            .fill(foreground.opacity(0.09))
            .overlay {
                VStack(spacing: 10 * unit) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 70 * unit, weight: .light))
                    Text(block.chart.map { "\($0.source.strongs) in \($0.source.translationID)" } ?? "Chart")
                        .font(.system(size: 20 * unit))
                        .lineLimit(1)
                }
                .foregroundStyle(foreground.opacity(0.7))
            }
    }
}
