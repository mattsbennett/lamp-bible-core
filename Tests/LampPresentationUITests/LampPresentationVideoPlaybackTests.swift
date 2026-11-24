import AVFoundation
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

    @Test @MainActor func aFileWithNoPicturesToPlayLeavesTheStill() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        try Data("not a video".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let playback = await LampPresentationVideoPlayback.prepared(url: url, tint: nil, theme: .lampDark)
        #expect(playback == nil)
    }

    @Test @MainActor func aVideoWithSoundPlaysItsPicturesSilentlyAndUpright() async throws {
        // A phone's portrait clip: filmed sideways, marked to be turned, with
        // a soundtrack.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let pictures = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 32,
        ])
        pictures.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 32, ty: 0)
        let sound = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: pictures, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 32,
        ])
        writer.add(pictures)
        writer.add(sound)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !pictures.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer!), width: 64, height: 32, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer!), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 16, width: 32, height: 16))
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        // A second of silence.
        var format: CMAudioFormatDescription?
        var description = AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var silence = [Int16](repeating: 0, count: 44_100)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: silence.count * 2,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: silence.count * 2, flags: 0, blockBufferOut: &block)
        CMBlockBufferReplaceDataBytes(with: &silence, blockBuffer: block!, offsetIntoDestination: 0, dataLength: silence.count * 2)
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format!,
            sampleCount: silence.count, presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample)
        while !sound.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        sound.append(sample!)
        pictures.markAsFinished()
        sound.markAsFinished()
        await writer.finishWriting()
        #expect(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).count == 1)

        let playback = try #require(await LampPresentationVideoPlayback.prepared(url: url, tint: nil, theme: .lampDark))
        #expect(playback.soundTracks == 0)
        playback.start()
        defer { playback.stop() }
        var waited = 0
        while playback.frame == nil && waited < 100 { try await Task.sleep(for: .milliseconds(50)); waited += 1 }
        let frame = try #require(playback.frame)
        // Shown as filmed: upright, taller than wide.
        #expect(frame.height > frame.width)
    }
}
