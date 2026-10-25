import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import LampCore

/// Reads a picture as a slide will show it behind its words.
///
/// The canvas fills the slide with the picture and centres it, cropping what
/// overflows, so the sampler crops the same way before it looks: a portrait
/// photograph behind a widescreen slide loses its top and bottom in both.
enum LampPresentationBackdropSampler {
    /// Cells across a widescreen slide, about ten design units each — a little
    /// more than one stroke of a 48-unit heading.
    static let widescreenColumns = 160
    static let rows = 90
    /// Samples along each side of a cell. The darkest and lightest are taken
    /// from these, each already an average of the pixels under it, so a single
    /// noisy pixel does not count as a highlight.
    static let samplesPerCell = 3

    static func backdrop(
        from image: CGImage,
        aspectRatio: LampPresentationAspectRatio
    ) -> LampPresentationBackdrop? {
        let columns = aspectRatio == .widescreen
            ? widescreenColumns
            : widescreenColumns * 3 / 4
        let width = columns * samplesPerCell
        let height = rows * samplesPerCell

        // The part of the picture the slide shows.
        let slideRatio = aspectRatio.ratio
        let imageRatio = Double(image.width) / Double(image.height)
        let shown: CGRect
        if imageRatio > slideRatio {
            let shownWidth = Double(image.height) * slideRatio
            shown = CGRect(
                x: (Double(image.width) - shownWidth) / 2,
                y: 0,
                width: shownWidth,
                height: Double(image.height)
            )
        } else {
            let shownHeight = Double(image.width) / slideRatio
            shown = CGRect(
                x: 0,
                y: (Double(image.height) - shownHeight) / 2,
                width: Double(image.width),
                height: shownHeight
            )
        }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &pixels,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        // The words are drawn over the picture blurred by
        // `LampPresentationBackdrop.softening`, so it is read blurred as well.
        let designWidth = aspectRatio == .widescreen ? 1_600.0 : 1_200.0
        let picture = softened(
            image,
            radius: LampPresentationBackdrop.softening * shown.width / designWidth
        ) ?? image
        // Scale the whole picture so that the shown part lands exactly on the
        // bitmap; Core Graphics clips the rest.
        let scaleX = Double(width) / shown.width
        let scaleY = Double(height) / shown.height
        context.draw(
            picture,
            in: CGRect(
                x: -shown.minX * scaleX,
                y: -(Double(image.height) - shown.maxY) * scaleY,
                width: Double(image.width) * scaleX,
                height: Double(image.height) * scaleY
            )
        )

        // The bitmap's first row in memory is the top of the picture.
        var cells: [LampPresentationBackdrop.Cell] = []
        cells.reserveCapacity(columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                var darkest: (LampPresentationColor, Double)?
                var lightest: (LampPresentationColor, Double)?
                for dy in 0..<samplesPerCell {
                    for dx in 0..<samplesPerCell {
                        let x = column * samplesPerCell + dx
                        let y = row * samplesPerCell + dy
                        let offset = y * bytesPerRow + x * 4
                        let color = LampPresentationColor(
                            red: Double(pixels[offset]) / 255,
                            green: Double(pixels[offset + 1]) / 255,
                            blue: Double(pixels[offset + 2]) / 255
                        )
                        let luminance = color.luminance
                        if darkest.map({ luminance < $0.1 }) ?? true { darkest = (color, luminance) }
                        if lightest.map({ luminance > $0.1 }) ?? true { lightest = (color, luminance) }
                    }
                }
                cells.append(.init(darkest: darkest!.0, lightest: lightest!.0))
            }
        }
        return LampPresentationBackdrop(columns: columns, rows: rows, cells: cells)
    }

    /// The context the blur is drawn through.
    ///
    /// Made once and kept: a `CIContext` compiles its kernels and claims its
    /// drawing resources as it is created, which measured 8 to 15 ms against
    /// 1 ms for the blur itself. One per picture made opening a deck pay that
    /// cost for nothing.
    private static let softeningContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
    ])

    /// `image` blurred by `radius` pixels, the edges held rather than faded
    /// to transparent, as SwiftUI's opaque blur holds them.
    static func softened(_ image: CGImage, radius: Double) -> CGImage? {
        guard radius > 0 else { return image }
        let input = CIImage(cgImage: image)
        let blurred = input
            .clampedToExtent()
            .applyingGaussianBlur(sigma: radius)
            .cropped(to: input.extent)
        return softeningContext.createCGImage(blurred, from: input.extent)
    }

    /// Reads the file at `url` small enough to be quick, upright as it will
    /// be drawn.
    static func backdrop(
        at url: URL,
        aspectRatio: LampPresentationAspectRatio
    ) -> LampPresentationBackdrop? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 1_440,
                  ] as CFDictionary
              )
        else { return nil }
        return backdrop(from: image, aspectRatio: aspectRatio)
    }
}
