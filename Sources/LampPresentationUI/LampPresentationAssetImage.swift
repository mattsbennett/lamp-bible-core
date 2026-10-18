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
    private static func backdropKey(_ url: URL, _ aspectRatio: LampPresentationAspectRatio) -> String {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?
            .timeIntervalSince1970 ?? 0
        return "\(url.path)@\(modified)#\(aspectRatio.rawValue)"
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
        theme: LampPresentationTheme
    ) -> LampPresentationBackdrop.Treatment? {
        let places = regions.map { region -> String in
            guard !region.isNull, !region.isEmpty, !region.isInfinite else { return "-" }
            return [region.minX, region.minY, region.width, region.height]
                .map { String(Int(($0 * 1_000).rounded())) }
                .joined(separator: ",")
        }
        let key = [
            backdropKey(url, aspectRatio),
            theme.foregroundColor,
            theme.backgroundColor,
            theme.accentColor,
            places.joined(separator: ";"),
        ].joined(separator: "|") as NSString
        if let cached = treatments.object(forKey: key) { return cached.treatment }
        guard let backdrop = backdrop(at: url, aspectRatio: aspectRatio) else { return nil }
        let treatment = backdrop.treatment(for: regions, theme: theme)
        treatments.setObject(TreatmentBox(treatment), forKey: key)
        return treatment
    }

    /// The picture at `url` read for the words to be laid over it, kept with
    /// the same key as the image so a replaced file is read again.
    static func backdrop(
        at url: URL,
        aspectRatio: LampPresentationAspectRatio
    ) -> LampPresentationBackdrop? {
        let key = backdropKey(url, aspectRatio) as NSString
        if let cached = backdrops.object(forKey: key) { return cached.backdrop }
        guard let backdrop = LampPresentationBackdropSampler.backdrop(
            at: url,
            aspectRatio: aspectRatio
        ) else { return nil }
        backdrops.setObject(BackdropBox(backdrop), forKey: key)
        return backdrop
    }

    static func swiftUIImage(at url: URL) -> Image? {
        guard let platformImage = image(at: url) else { return nil }
        #if canImport(UIKit)
        return Image(uiImage: platformImage)
        #elseif canImport(AppKit)
        return Image(nsImage: platformImage)
        #else
        return nil
        #endif
    }
}
