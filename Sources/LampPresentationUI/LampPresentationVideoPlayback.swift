import AVFoundation
import CoreImage
import LampCore
import Observation
import QuartzCore
import SwiftUI

/// A picture's video (`LampPresentationBlock.video`) playing on a presented
/// slide: silent, looping, and handed over a frame at a time as a `CGImage`.
///
/// Frames rather than a player layer, so a video is drawn exactly as a still
/// picture is: cropped around the same focus, tinted by the same filter,
/// drifting with the same scale, and softened behind the words by the same
/// blur. Every layer that draws the picture reads the one `frame`, so the
/// picture and its softened copy show the same moment on every refresh.
@MainActor
@Observable
final class LampPresentationVideoPlayback {
    /// The latest frame, upright and in the picture's tint. Nil until the
    /// first arrives, while the still stands in.
    private(set) var frame: CGImage?

    @ObservationIgnored private let player = AVQueuePlayer()
    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var outputs: [ObjectIdentifier: AVPlayerItemVideoOutput] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var orientation: CGAffineTransform = .identity
    @ObservationIgnored private let tint: LampPresentationImageTint?
    @ObservationIgnored private let theme: LampPresentationTheme
    /// The sound tracks the played item carries, which is none.
    @ObservationIgnored private(set) var soundTracks = 0

    /// Frames are asked for this often. A slow background loop needs no more,
    /// and every frame is a conversion the presenter's machine pays for.
    static let framesPerSecond = 30.0

    /// A playback of the video at `url`, or nil where it has no pictures to
    /// play, or none that last: the still stands in, rather than the looper
    /// refusing an empty clip by bringing the presenter down.
    ///
    /// Played from its pictures alone. A silent picture needs no sound, and
    /// a muted player still holding a soundtrack can take the device's audio
    /// and stop the music someone was listening to.
    static func prepared(
        url: URL,
        tint: LampPresentationImageTint?,
        theme: LampPresentationTheme
    ) async -> LampPresentationVideoPlayback? {
        let asset = AVURLAsset(url: url)
        // The picture track the file shows and Lamp can play: a file may
        // carry another, hidden or in a form this device cannot decode.
        var shown: (track: AVAssetTrack, range: CMTimeRange)?
        for candidate in (try? await asset.loadTracks(withMediaType: .video)) ?? [] {
            guard (try? await candidate.load(.isEnabled)) == true,
                  (try? await candidate.load(.isPlayable)) == true,
                  let range = try? await candidate.load(.timeRange),
                  range.duration.seconds.isFinite, range.duration.seconds > 0
            else { continue }
            shown = (candidate, range)
            break
        }
        guard let (track, range) = shown,
              // A phone films upright by recording sideways and saying so;
              // the frames arrive as recorded.
              let transform = try? await track.load(.preferredTransform)
        else { return nil }
        let composition = AVMutableComposition()
        guard let pictures = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ), (try? pictures.insertTimeRange(range, of: track, at: .zero)) != nil
        else { return nil }
        return LampPresentationVideoPlayback(
            item: AVPlayerItem(asset: composition), orientation: transform, tint: tint, theme: theme
        )
    }

    /// A playback of a clip (`LampPresentationClip`): the file at `url` with
    /// its sound, from `start` to `end`, once, holding its last frame. Nil
    /// where it has no pictures Lamp can play.
    static func preparedClip(
        url: URL,
        start: Double?,
        end: Double?,
        tint: LampPresentationImageTint?,
        theme: LampPresentationTheme
    ) async -> LampPresentationVideoPlayback? {
        let asset = AVURLAsset(url: url)
        var transform: CGAffineTransform?
        for candidate in (try? await asset.loadTracks(withMediaType: .video)) ?? [] {
            guard (try? await candidate.load(.isEnabled)) == true,
                  (try? await candidate.load(.isPlayable)) == true,
                  let range = try? await candidate.load(.timeRange),
                  range.duration.seconds.isFinite, range.duration.seconds > 0
            else { continue }
            transform = try? await candidate.load(.preferredTransform)
            break
        }
        guard let transform else { return nil }
        let item = AVPlayerItem(asset: asset)
        let from = start.flatMap { $0.isFinite && $0 > 0 ? CMTime(seconds: $0, preferredTimescale: 600) : nil }
        if let end, end.isFinite, end > (start ?? 0) {
            item.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 600)
        }
        return LampPresentationVideoPlayback(
            clip: item, from: from ?? .zero, orientation: transform, tint: tint, theme: theme
        )
    }

    private init(
        item: AVPlayerItem,
        orientation: CGAffineTransform,
        tint: LampPresentationImageTint?,
        theme: LampPresentationTheme
    ) {
        self.tint = tint
        self.theme = theme
        self.orientation = orientation
        soundTracks = item.asset.tracks.filter { $0.mediaType == .audio }.count
        player.isMuted = true
        player.actionAtItemEnd = .advance
        looper = AVPlayerLooper(player: player, templateItem: item)
    }

    private init(
        clip item: AVPlayerItem,
        from start: CMTime,
        orientation: CGAffineTransform,
        tint: LampPresentationImageTint?,
        theme: LampPresentationTheme
    ) {
        self.tint = tint
        self.theme = theme
        self.orientation = orientation
        self.clipStart = start
        soundTracks = item.asset.tracks.filter { $0.mediaType == .audio }.count
        player.actionAtItemEnd = .pause
        player.insert(item, after: nil)
        item.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
    }

    /// Where a clip starts; nil for a picture's looping video.
    @ObservationIgnored private var clipStart: CMTime?

    /// Pauses a clip where it is, keeping its frame.
    func pause() {
        player.pause()
    }

    /// Takes a clip back to its start, showing the still again, ready to
    /// play from the beginning.
    func rewind() {
        stop()
        frame = nil
        if let clipStart {
            player.currentItem?.seek(to: clipStart, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
        }
    }

    /// `frame` turned as a track's `preferredTransform` says it is shown.
    ///
    /// The transform is written for a picture measured from its top left,
    /// and Core Image measures from the bottom left, so applying it as it is
    /// turns a quarter-turned clip the wrong way. It is read instead as the
    /// orientation it describes, which Core Image applies correctly.
    nonisolated static func upright(_ frame: CIImage, transform: CGAffineTransform) -> CIImage {
        func near(_ value: CGFloat, _ target: CGFloat) -> Bool { abs(value - target) < 0.001 }
        let t = transform
        let orientation: CGImagePropertyOrientation
        switch true {
        case near(t.a, 0) && near(t.b, 1) && near(t.c, -1) && near(t.d, 0): orientation = .right
        case near(t.a, 0) && near(t.b, -1) && near(t.c, 1) && near(t.d, 0): orientation = .left
        case near(t.a, -1) && near(t.b, 0) && near(t.c, 0) && near(t.d, -1): orientation = .down
        case near(t.a, -1) && near(t.b, 0) && near(t.c, 0) && near(t.d, 1): orientation = .upMirrored
        case near(t.a, 1) && near(t.b, 0) && near(t.c, 0) && near(t.d, -1): orientation = .downMirrored
        case near(t.a, 0) && near(t.b, 1) && near(t.c, 1) && near(t.d, 0): orientation = .leftMirrored
        case near(t.a, 0) && near(t.b, -1) && near(t.c, -1) && near(t.d, 0): orientation = .rightMirrored
        default: return frame
        }
        let turned = frame.oriented(orientation)
        return turned.transformed(by: CGAffineTransform(translationX: -turned.extent.minX, y: -turned.extent.minY))
    }

    func start() {
        player.play()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1 / Self.framesPerSecond, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pull() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        player.pause()
        timer?.invalidate()
        timer = nil
    }

    /// The frame reader on `item`, added the first time it plays: the looper
    /// makes its copies of the clip only once the clip has loaded.
    private func output(for item: AVPlayerItem) -> AVPlayerItemVideoOutput {
        if let output = outputs[ObjectIdentifier(item)] { return output }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)
        outputs[ObjectIdentifier(item)] = output
        return output
    }

    private func pull() {
        guard let item = player.currentItem else { return }
        let output = output(for: item)
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
        else { return }
        let image = Self.upright(CIImage(cvPixelBuffer: buffer), transform: orientation)
        frame = LampPresentationTint.rendered(image, tint, theme: theme)
    }
}

/// A clip a presented slide plays, from where, and between which times:
/// what a clip's playback is prepared for.
struct LampPresentationPlayingClip: Equatable {
    enum Origin: Equatable {
        case file(URL)
        case streamed(LampPresentationClip.Origin)
    }

    var blockID: String
    var origin: Origin
    var start: Double?
    var end: Double?
    var tint: LampPresentationImageTint?
}

/// Which video a presented slide plays, and in what tint: what a new
/// playback is started for, and restarted when it changes.
struct LampPresentationPlayingVideo: Equatable {
    var blockID: String
    var url: URL
    var tint: LampPresentationImageTint?
}

/// Draws `content` with the playback's latest frame, or with nil while there
/// is none, for the still to stand in.
///
/// Its own view, so a new frame redraws only the pictures that show it, not
/// the slide's words.
struct LampPresentationVideoFrame<Content: View>: View {
    var playback: LampPresentationVideoPlayback?
    @ViewBuilder var content: ((image: Image, size: CGSize)?) -> Content

    var body: some View {
        if let frame = playback?.frame {
            content((Image(decorative: frame, scale: 1), CGSize(width: frame.width, height: frame.height)))
        } else {
            content(nil)
        }
    }
}
