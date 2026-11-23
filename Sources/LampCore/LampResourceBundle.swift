import Foundation

/// Finds a core target's resource bundle wherever the program that links it
/// keeps it, without SwiftPM's `Bundle.module`, which stops the program when
/// it looks in the wrong place.
///
/// The Mac app keeps the package bundles in its `Contents/Resources`, and its
/// `lamp-mcp` helper runs from `Contents/Helpers`, where `Bundle.module` looks
/// beside the helper and finds nothing. An iPhone app keeps them at its top
/// level; a test run, beside the test bundle; a command-line build, beside the
/// executable. A missing bundle is nil, and what reads from it says so, rather
/// than a crash in a tool an agent called.
public enum LampResourceBundle {
    /// The bundle SwiftPM builds for `target` of this package, if any copy
    /// of it can be found.
    public static func named(_ target: String) -> Bundle? {
        let name = "lamp-bible-core_\(target).bundle"
        var places: [URL] = []
        if let resources = Bundle.main.resourceURL { places.append(resources) }
        places.append(Bundle.main.bundleURL)
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let folder = executable.deletingLastPathComponent()
            places.append(folder)
            // An app's helper: Contents/Helpers beside Contents/Resources.
            places.append(folder.deletingLastPathComponent().appendingPathComponent("Resources"))
        }
        // Whatever bundle this code was linked into, and the folder around
        // it, which is where a test run keeps the resource bundles.
        let linked = Bundle(for: Marker.self)
        places.append(linked.bundleURL.deletingLastPathComponent())
        if let resources = linked.resourceURL { places.append(resources) }
        for place in places {
            let candidate = place.appendingPathComponent(name)
            if let bundle = Bundle(url: candidate) { return bundle }
        }
        return nil
    }

    private final class Marker {}
}
