import LampCore
import SwiftUI

/// A chart block's bars, in the slide's colours, at any size.
///
/// The bars run across, because their labels are book names and English
/// words, which read across rather than up. The accent marks a book or
/// section holding more than its share of the words predicts, and one holding
/// notably fewer is drawn fainter than the rest; a key says so whenever either
/// appears, since colour alone tells a room nothing.
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
                bars(chart, values)
            } else {
                placeholder
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(block.chart?.spokenDescription ?? "Chart")
    }

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
