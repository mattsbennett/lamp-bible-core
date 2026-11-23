import LampCore
import SwiftUI

/// How a presenter moves, shared so every presenter moves alike: a slide
/// dissolving into the next, or cutting, and a part of a slide fading in.
///
/// Unhurried, since a change the room notices as motion has taken too long
/// or gone too far, and nothing at all with Reduce Motion on, which the
/// presenter reads at each move rather than once.
extension LampPresentationTransition {
    /// The animation for a move: to another slide when `changesSlide`, else
    /// a step within one. Nil means no animation.
    public func animation(changesSlide: Bool, reduceMotion: Bool) -> Animation? {
        if reduceMotion { return nil }
        if changesSlide { return self == .cut ? nil : .easeInOut(duration: 0.45) }
        return .easeInOut(duration: 0.35)
    }
}

extension AnyTransition {
    /// A presented slide's transition: the arriving slide fades in over the
    /// one leaving, which stays whole beneath it until it has gone. Both
    /// fading at once over the black behind dimmed the screen midway, even
    /// between two slides of the same colour.
    ///
    /// Give each slide a `.zIndex` above the one before, whichever way the
    /// presenter moves, so the arriving one is always drawn on top.
    public static var lampSlide: AnyTransition {
        .asymmetric(insertion: .opacity, removal: .modifier(
            active: LampSlideHeldUntilCovered(progress: 0),
            identity: LampSlideHeldUntilCovered(progress: 1)
        ))
    }
}

/// A slide leaving during a dissolve, drawn as it is. Its two states differ
/// only in a value nothing reads, which is enough for SwiftUI to keep the
/// view until the animation ends instead of removing it at once.
struct LampSlideHeldUntilCovered: ViewModifier, Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View { content }
}

/// A picture drifting (`LampPresentationImageMotion.drift`) from `since`,
/// closing in on `anchor`; still when `since` is nil.
///
/// Timed from a date rather than animated, so two layers given the same
/// date are at the same scale on every frame however late either appeared.
/// Thirty frames a second is plenty for a picture whose edge moves about a
/// point a second.
struct LampPresentationDrift: ViewModifier {
    var since: Date?
    var anchor: UnitPoint

    func body(content: Content) -> some View {
        if let since {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                content.scaleEffect(
                    LampPresentationImageMotion.driftScale(after: context.date.timeIntervalSince(since)),
                    anchor: anchor
                )
            }
        } else {
            content
        }
    }
}
