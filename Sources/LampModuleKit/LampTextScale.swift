import Foundation

/// A bounded, steppable text measurement, a point size or a line spacing, that
/// several controls have to agree on: a slider in settings, the increase and
/// decrease buttons in a text-size menu, and the stored default they both
/// reset to. Keeping the bounds in one value means a size nudged to its limit
/// in the menu is still a size the slider can express.
///
/// Shared so that a size means the same in both apps. A chosen size stays on
/// the device it was chosen on: screens differ, so it doesn't travel.
public struct LampTextScale: Equatable, Sendable {
    public let minimum: Double
    public let maximum: Double
    public let step: Double
    public let defaultValue: Double

    public init(minimum: Double, maximum: Double, step: Double, defaultValue: Double) {
        self.minimum = minimum
        self.maximum = max(maximum, minimum)
        self.step = max(step, 0.01)
        self.defaultValue = min(max(defaultValue, minimum), max(maximum, minimum))
    }

    public var range: ClosedRange<Double> { minimum...maximum }

    public func clamped(_ value: Double) -> Double {
        min(max(value, minimum), maximum)
    }

    /// Moves `value` by whole steps, snapping onto the step grid on the way. A
    /// stored size that predates a change of step, or that a slider left
    /// between grid points, otherwise carries its offset forward forever.
    public func stepped(_ value: Double, by steps: Int) -> Double {
        let current = clamped(value)
        guard steps != 0 else { return current }
        let offset = (current - minimum) / step
        // Snap toward the direction of travel first, so a nudge upward from
        // 20.5 lands on 21 rather than 21.5, and a nudge downward on 20.
        let snapped = steps > 0 ? (offset + 1e-9).rounded(.down) : (offset - 1e-9).rounded(.up)
        return clamped(minimum + (snapped + Double(steps)) * step)
    }

    public func canIncrease(_ value: Double) -> Bool {
        clamped(value) < maximum - 1e-9
    }

    public func canDecrease(_ value: Double) -> Bool {
        clamped(value) > minimum + 1e-9
    }
}

public extension LampTextScale {
    /// Long-form books need a comfortable prose default while still allowing
    /// compact reference works and large-print reading.
    static let bookText = LampTextScale(
        minimum: 13,
        maximum: 34,
        step: 1,
        defaultValue: 18
    )

    static let bookLineSpacing = LampTextScale(
        minimum: 0,
        maximum: 16,
        step: 1,
        defaultValue: 6
    )
}

/// The typeface a reader sets prose in, by the raw value both apps store. How
/// each looks, and what it is called on screen, is each app's own.
public enum LampProseTypeface: String, CaseIterable, Sendable {
    case serif
    case sansSerif
}
