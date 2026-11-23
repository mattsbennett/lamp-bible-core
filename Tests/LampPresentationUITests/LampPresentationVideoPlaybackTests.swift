import CoreGraphics
import CoreImage
import Testing
@testable import LampPresentationUI

/// A clip filmed on its side and marked to be turned is shown as its still
/// is: the turn read from the track's transform, not applied as Core Image
/// coordinates, which turned a quarter-turned clip the wrong way.
struct LampPresentationVideoPlaybackTests {
    /// A 4 by 2 frame, red in its top-left pixel and blue elsewhere.
    private func frame() -> CIImage {
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 1, width: 1, height: 1))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 2))
        return red.composited(over: blue)
    }

    /// Where the red pixel lands, from the top left, once turned.
    private func red(after transform: CGAffineTransform) throws -> (x: Int, y: Int, width: Int, height: Int) {
        let turned = LampPresentationVideoPlayback.upright(frame(), transform: transform)
        let width = Int(turned.extent.width), height = Int(turned.extent.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        CIContext().render(
            turned, toBitmap: &pixels, rowBytes: width * 4, bounds: turned.extent,
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        // Rows come out top first.
        let index = try #require(stride(from: 0, to: pixels.count, by: 4).first { pixels[$0] > 200 && pixels[$0 + 2] < 50 })
        let pixel = index / 4
        return (pixel % width, pixel / width, width, height)
    }

    @Test func eachTurnShowsTheClipAsItsStill() throws {
        let still = try red(after: .identity)
        #expect(still.x == 0 && still.y == 0 && still.width == 4)
        // A quarter turn clockwise, as a phone held upright records.
        let clockwise = try red(after: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 2, ty: 0))
        #expect(clockwise.width == 2 && clockwise.height == 4)
        #expect(clockwise.x == 1 && clockwise.y == 0)
        let anticlockwise = try red(after: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 4))
        #expect(anticlockwise.x == 0 && anticlockwise.y == 3)
        let halfTurn = try red(after: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 4, ty: 2))
        #expect(halfTurn.x == 3 && halfTurn.y == 1)
    }
}
