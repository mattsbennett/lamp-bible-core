import CoreGraphics
import CoreImage
import LampCore

/// Draws a picture in a deck's colours (`LampPresentationImageTint`).
///
/// The same function serves what is shown and what is sampled for the words'
/// colour, so the words are chosen for the picture as the room sees it.
enum LampPresentationTint {
    /// Made once: a `CIContext` is slow to create and safe to share.
    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
    ])

    /// `image` in `tint` for `theme`, or the image itself for none.
    static func tinted(
        _ image: CGImage,
        _ tint: LampPresentationImageTint?,
        theme: LampPresentationTheme
    ) -> CGImage? {
        guard let tint, tint != .none else { return image }
        let input = CIImage(cgImage: image)
        let output: CIImage
        switch tint {
        case .none:
            return image
        case .duotone:
            let ends = LampPresentationImageTint.duotone(of: theme)
            guard let dark = ciColor(ends.dark), let light = ciColor(ends.light) else { return image }
            output = input
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
                .applyingFilter("CIFalseColor", parameters: ["inputColor0": dark, "inputColor1": light])
        case .muted:
            guard let ground = LampPresentationColor(hex: theme.backgroundColor) else { return image }
            let wash = CIImage(color: CIColor(
                red: ground.red, green: ground.green, blue: ground.blue,
                alpha: LampPresentationImageTint.mutedWash
            )).cropped(to: input.extent)
            // Atop, not over: the wash colours the picture where it is and
            // leaves its transparency as it was, so a cut-out picture does
            // not gain a tinted rectangle around it.
            output = wash.applyingFilter("CISourceAtopCompositing", parameters: [
                kCIInputBackgroundImageKey: input.applyingFilter(
                    "CIColorControls",
                    parameters: [kCIInputSaturationKey: LampPresentationImageTint.mutedSaturation]
                ),
            ])
        }
        return context.createCGImage(output, from: input.extent)
    }

    private static func ciColor(_ hex: String) -> CIColor? {
        LampPresentationColor(hex: hex).map { CIColor(red: $0.red, green: $0.green, blue: $0.blue) }
    }

    /// What a cache tells one tinted picture from another by: the tint and
    /// the colours it is drawn in.
    static func key(_ tint: LampPresentationImageTint?, theme: LampPresentationTheme) -> String {
        switch tint ?? .none {
        case .none: "none"
        case .duotone: "duotone:\(theme.accentColor):\(theme.backgroundColor)"
        case .muted: "muted:\(theme.backgroundColor)"
        }
    }
}
