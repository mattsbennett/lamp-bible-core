import Foundation
import LampCore
import SwiftUI

#if canImport(UIKit)
import UIKit
typealias LampPlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias LampPlatformImage = NSImage
#endif

/// Loads deck images off disk, once.
///
/// A slide canvas re-evaluates its body freely — on every scroll, resize, and
/// page turn — so decoding an image inside `body` would re-read the file each
/// time. Decoded images are held here instead, keyed by file and modification
/// date so a replaced image is picked up rather than served stale.
enum LampPresentationAssetImageCache {
    private static let cache: NSCache<NSString, LampPlatformImage> = {
        let cache = NSCache<NSString, LampPlatformImage>()
        cache.countLimit = 64
        return cache
    }()

    private static let missing = NSCache<NSString, NSNull>()

    static func image(at url: URL) -> LampPlatformImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?
            .timeIntervalSince1970 ?? 0
        let key = "\(url.path)@\(modified)" as NSString

        if let cached = cache.object(forKey: key) { return cached }
        // A deck can outlive its images — a sync that has not yet carried them,
        // or a file the author moved. Remember the miss so a slide showing a
        // placeholder does not retry the disk on every redraw.
        if missing.object(forKey: key) != nil { return nil }

        guard let data = try? Data(contentsOf: url),
              let image = LampPlatformImage(data: data) else {
            missing.setObject(NSNull(), forKey: key)
            return nil
        }
        cache.setObject(image, forKey: key)
        return image
    }

    /// The picture at `url` in `tint` for `theme`, made once and kept.
    static func image(
        at url: URL,
        tint: LampPresentationImageTint?,
        theme: LampPresentationTheme
    ) -> LampPlatformImage? {
        guard let base = image(at: url) else { return nil }
        guard let tint, tint != .none else { return base }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?
            .timeIntervalSince1970 ?? 0
        let key = "\(url.path)@\(modified)#\(LampPresentationTint.key(tint, theme: theme))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        #if canImport(UIKit)
        guard let cgImage = base.cgImage,
              let tinted = LampPresentationTint.tinted(cgImage, tint, theme: theme) else { return base }
        // The orientation the file asked for, which a CGImage does not carry.
        let image = UIImage(cgImage: tinted, scale: base.scale, orientation: base.imageOrientation)
        #elseif canImport(AppKit)
        guard let cgImage = base.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let tinted = LampPresentationTint.tinted(cgImage, tint, theme: theme) else { return base }
        let image = NSImage(cgImage: tinted, size: base.size)
        #endif
        cache.setObject(image, forKey: key)
        return image
    }

    /// The picture's shape, width over height, as drawn.
    static func size(at url: URL) -> CGSize? {
        image(at: url)?.size
    }

    private final class BackdropBox {
        let backdrop: LampPresentationBackdrop
        init(_ backdrop: LampPresentationBackdrop) { self.backdrop = backdrop }
    }

    private static let backdrops: NSCache<NSString, BackdropBox> = {
        let cache = NSCache<NSString, BackdropBox>()
        cache.countLimit = 64
        return cache
    }()

    private final class TreatmentBox {
        let treatment: LampPresentationBackdrop.Treatment
        init(_ treatment: LampPresentationBackdrop.Treatment) { self.treatment = treatment }
    }

    private static let treatments: NSCache<NSString, TreatmentBox> = {
        let cache = NSCache<NSString, TreatmentBox>()
        cache.countLimit = 256
        return cache
    }()

    /// The file at `url` as it stands, so a replaced file is read again.
    /// The file at `url` as it stands, and as the slide shows it: its crop
    /// and its tint, so a picture moved or recoloured is read again.
    private static func backdropKey(
        _ url: URL,
        _ aspectRatio: LampPresentationAspectRatio,
        _ look: BackdropLook
    ) -> String {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?
            .timeIntervalSince1970 ?? 0
        // Only a focus the crop would use: an out-of-range one is drawn as
        // the centre, and the preview reads decks it has not validated, so a
        // huge value must not reach the conversion to an integer.
        let focus = look.focus.flatMap { $0.isValid ? $0 : nil }
            .map { "\(Int(($0.x * 1_000).rounded())),\(Int(($0.y * 1_000).rounded()))" } ?? "-"
        return "\(url.path)@\(modified)#\(aspectRatio.rawValue)#\(focus)#\(LampPresentationTint.key(look.tint, theme: look.theme))"
    }

    /// How a picture behind a slide is shown: where its crop sits, and how it
    /// is tinted in which theme's colours.
    struct BackdropLook {
        var focus: LampPresentationFocus?
        var tint: LampPresentationImageTint?
        var theme: LampPresentationTheme
    }

    /// How words in `regions` are set over the picture at `url`, remembered.
    ///
    /// Choosing reads every cell under the words a dozen times over, and a
    /// slide is drawn again whenever anything around it changes — as a
    /// thumbnail and on the stage alike. Regions are fractions of the slide,
    /// so a slide drawn at any size asks the same question and gets the same
    /// answer.
    static func treatment(
        for regions: [CGRect],
        over url: URL,
        aspectRatio: LampPresentationAspectRatio,
        theme: LampPresentationTheme,
        look: BackdropLook,
        moments: Int = 1,
        overAnything: Bool = false
    ) -> LampPresentationBackdrop.Treatment? {
        let places = regions.map { region -> String in
            guard !region.isNull, !region.isEmpty, !region.isInfinite else { return "-" }
            return [region.minX, region.minY, region.width, region.height]
                .map { String(Int(($0 * 1_000).rounded())) }
                .joined(separator: ",")
        }
        let key = [
            backdropKey(url, aspectRatio, look),
            theme.foregroundColor,
            theme.backgroundColor,
            theme.accentColor,
            (theme.highlights ?? [:]).sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ","),
            places.joined(separator: ";"),
            "\(moments)",
            "\(overAnything)",
        ].joined(separator: "|") as NSString
        if let cached = treatments.object(forKey: key) { return cached.treatment }
        guard let backdrop = backdrop(at: url, aspectRatio: aspectRatio, look: look) else { return nil }
        let treatment = backdrop.treatment(for: regions, theme: theme, moments: moments, overAnything: overAnything)
        treatments.setObject(TreatmentBox(treatment), forKey: key)
        return treatment
    }

    /// The picture at `url` read for the words to be laid over it, kept with
    /// the same key as the image so a replaced file is read again.
    static func backdrop(
        at url: URL,
        aspectRatio: LampPresentationAspectRatio,
        look: BackdropLook
    ) -> LampPresentationBackdrop? {
        let key = backdropKey(url, aspectRatio, look) as NSString
        if let cached = backdrops.object(forKey: key) { return cached.backdrop }
        guard let backdrop = LampPresentationBackdropSampler.backdrop(
            at: url,
            aspectRatio: aspectRatio,
            focus: look.focus,
            tint: look.tint,
            theme: look.theme
        ) else { return nil }
        backdrops.setObject(BackdropBox(backdrop), forKey: key)
        return backdrop
    }

    static func swiftUIImage(
        at url: URL,
        tint: LampPresentationImageTint? = nil,
        theme: LampPresentationTheme? = nil
    ) -> Image? {
        let platformImage = theme.map { image(at: url, tint: tint, theme: $0) } ?? image(at: url)
        guard let platformImage else { return nil }
        #if canImport(UIKit)
        return Image(uiImage: platformImage)
        #elseif canImport(AppKit)
        return Image(nsImage: platformImage)
        #else
        return nil
        #endif
    }
}
