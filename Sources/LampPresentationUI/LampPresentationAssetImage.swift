import Foundation
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
