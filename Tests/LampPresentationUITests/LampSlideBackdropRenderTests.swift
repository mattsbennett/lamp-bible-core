import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import LampCore
@testable import LampPresentationUI

/// Slides drawn over pictures made for the purpose, read back pixel by pixel.
@MainActor
struct LampSlideBackdropRenderTests {
    private let width = 1_600
    private let height = 900

    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        func color(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
            let offset = (y * width + x) * 4
            return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
        }

        /// Mean brightness, 0 to 255, of a region given in fractions.
        func meanBrightness(x: ClosedRange<Double>, y: ClosedRange<Double>) -> Double {
            var total = 0
            var count = 0
            for row in Int(y.lowerBound * Double(height))..<Int(y.upperBound * Double(height)) {
                for column in stride(
                    from: Int(x.lowerBound * Double(width)),
                    to: Int(x.upperBound * Double(width)),
                    by: 2
                ) {
                    let c = color(column, row)
                    total += (c.r + c.g + c.b) / 3
                    count += 1
                }
            }
            return count == 0 ? 0 : Double(total) / Double(count)
        }

        /// How many pixels in a region lie within `tolerance` of `hex`.
        func count(near hex: String, x: ClosedRange<Double>, y: ClosedRange<Double>, tolerance: Int = 24) -> Int {
            let target = LampPresentationColor(hex: hex)!
            let r = Int(target.red * 255)
            let g = Int(target.green * 255)
            let b = Int(target.blue * 255)
            var matches = 0
            for row in Int(y.lowerBound * Double(height))..<Int(y.upperBound * Double(height)) {
                for column in stride(
                    from: Int(x.lowerBound * Double(width)),
                    to: Int(x.upperBound * Double(width)),
                    by: 2
                ) {
                    let c = color(column, row)
                    if abs(c.r - r) + abs(c.g - g) + abs(c.b - b) <= tolerance { matches += 1 }
                }
            }
            return matches
        }
    }

    private func pixels(of image: CGImage) throws -> Pixels {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(
            data: &bytes,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Pixels(width: image.width, height: image.height, bytes: bytes)
    }

    /// Writes a picture drawn by `paint` to a temporary PNG.
    private func picture(
        width: Int = 1_200,
        height: Int = 800,
        _ paint: (CGContext) -> Void
    ) throws -> URL {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        paint(context)
        let image = try #require(context.makeImage())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-backdrop-\(UUID().uuidString).png")
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func solid(_ red: Double, _ green: Double, _ blue: Double) throws -> URL {
        try picture { context in
            context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        }
    }

    private func titleSlide(over url: URL?) -> LampPresentationSlide {
        LampPresentationSlide(layout: .title, blocks: [
            .init(
                kind: .image,
                assetPath: url == nil ? "Assets/missing.png" : "Assets/picture.png",
                altText: "A picture",
                placement: .background
            ),
            .init(kind: .title, text: "Has Mankind Evolved and Become Smarter?"),
        ])
    }

    private func render(
        _ slide: LampPresentationSlide,
        theme: LampPresentationTheme = .lampDark,
        picture url: URL?
    ) throws -> Pixels {
        let deck = LampPresentationDeck(title: "Backdrop", theme: theme, slides: [slide])
        let renderer = ImageRenderer(
            content: LampPresentationSlideCanvas(
                slide: slide,
                style: .init(deck: deck),
                assetURL: { $0.isBackground ? url : nil }
            )
            .frame(width: Double(width), height: Double(height))
        )
        renderer.scale = 1
        return try pixels(of: try #require(renderer.cgImage))
    }

    @Test("A picture behind a slide fills it to the corners")
    func pictureFillsTheSlide() throws {
        let url = try solid(0.75, 0.2, 0.2)
        defer { try? FileManager.default.removeItem(at: url) }
        let drawn = try render(titleSlide(over: url), picture: url)
        for (x, y) in [(4, 4), (width - 5, 4), (4, height - 5), (width - 5, height - 5)] {
            let c = drawn.color(x, y)
            #expect(c.r > 170 && c.g < 80 && c.b < 80, "corner \(x),\(y) is \(c)")
        }
    }

    @Test("Words over a pale picture are drawn in the theme's dark colour, and over a dark one in its light")
    func wordsTakeTheReadableColour() throws {
        let pale = try solid(1, 1, 1)
        let dark = try solid(0, 0, 0)
        defer {
            try? FileManager.default.removeItem(at: pale)
            try? FileManager.default.removeItem(at: dark)
        }
        let band = (x: 0.1...0.9, y: 0.35...0.65)
        let overPale = try render(titleSlide(over: pale), picture: pale)
        let overDark = try render(titleSlide(over: dark), picture: dark)
        // Lamp Dark's words are #F9FAFB on #111827.
        #expect(overPale.count(near: "#111827", x: band.x, y: band.y) > 2_000)
        #expect(overDark.count(near: "#F9FAFB", x: band.x, y: band.y, tolerance: 12) > 2_000)
        #expect(overDark.count(near: "#111827", x: band.x, y: band.y, tolerance: 12) == 0)
    }

    @Test("A busy picture is covered behind the words and left alone above them")
    func scrimSitsBehindTheWords() throws {
        // Black and white squares: no colour of text reads over this as it is.
        let url = try picture { context in
            for row in 0..<(context.height / 10) {
                for column in 0..<(context.width / 10) {
                    let on = (row + column).isMultiple(of: 2)
                    context.setFillColor(CGColor(gray: on ? 1 : 0, alpha: 1))
                    context.fill(CGRect(x: column * 10, y: row * 10, width: 10, height: 10))
                }
            }
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let drawn = try render(titleSlide(over: url), picture: url)
        // Beside the title, where there are no words, against the top of the
        // slide, which is well clear of them.
        let beside = drawn.meanBrightness(x: 0.0...0.05, y: 0.45...0.55)
        let above = drawn.meanBrightness(x: 0.0...0.05, y: 0.0...0.06)
        #expect(abs(above - 127) < 30, "the top of the slide is \(above)")
        #expect(abs(beside - above) > 40, "beside the words \(beside), above them \(above)")
    }

    @Test("A picture that cannot be read leaves the slide as it would be without one")
    func unreadablePictureChangesNothing() throws {
        let with = try render(titleSlide(over: nil), picture: nil)
        let without = try render(
            LampPresentationSlide(layout: .title, blocks: [
                .init(kind: .title, text: "Has Mankind Evolved and Become Smarter?"),
            ]),
            picture: nil
        )
        let differing = zip(with.bytes, without.bytes).filter { $0 != $1 }
        let largest = differing.map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(
            with.bytes == without.bytes,
            "\(differing.count) bytes differ, by up to \(largest)"
        )
    }

    @Test("The words are told how they were set")
    func treatmentIsReported() throws {
        let url = try solid(1, 1, 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let slide = titleSlide(over: url)
        let deck = LampPresentationDeck(title: "Backdrop", slides: [slide])
        var reported: LampPresentationBackdrop.Treatment?
        let renderer = ImageRenderer(
            content: LampPresentationSlideCanvas(
                slide: slide,
                style: .init(deck: deck),
                assetURL: { _ in url },
                reportsBackdrop: { reported = $0 }
            )
            .frame(width: Double(width), height: Double(height))
        )
        _ = renderer.cgImage
        #expect(reported?.text == LampPresentationTheme.lampDark.backgroundColor)
        #expect(reported?.scrimOpacity == 0)
    }

    @Test("The scrim runs in one band behind words that sit together, and in two behind words apart")
    func bandsJoinOnlyWhereTheirFadesMeet() {
        let close = LampPresentationSlideCanvas.bands(
            around: [CGRect(x: 0, y: 100, width: 10, height: 50), CGRect(x: 0, y: 200, width: 10, height: 50)],
            pad: 36,
            feather: 90
        )
        #expect(close == [64...286])
        let apart = LampPresentationSlideCanvas.bands(
            around: [CGRect(x: 0, y: 100, width: 10, height: 50), CGRect(x: 0, y: 700, width: 10, height: 50)],
            pad: 36,
            feather: 90
        )
        #expect(apart.count == 2)
    }
}
