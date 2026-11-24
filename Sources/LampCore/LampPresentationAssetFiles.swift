import Foundation
import LampModuleKit

/// The same file merge and pruning rules for the Mac author and iOS mirror.
public enum LampPresentationAssetFiles {
    @discardableResult
    public static func merge(
        _ incoming: [LampPresentationAssetRevision], into directory: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        guard !incoming.isEmpty else { return false }
        try requirePlainDirectory(directory.deletingLastPathComponent(), fileManager: fileManager)
        try requirePlainDirectory(directory, fileManager: fileManager)
        var changed = false
        for asset in incoming {
            guard LampPresentationDeckValidator.isSafeAssetPath("Assets/\(asset.name)"),
                  !asset.name.contains("/") else { continue }
            let target = directory.appendingPathComponent(asset.name)
            guard (try? fileManager.destinationOfSymbolicLink(atPath: target.path)) == nil else {
                continue
            }
            if fileManager.fileExists(atPath: target.path) {
                let values = try target.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                guard values.isRegularFile == true,
                      LampSyncMerge.shouldReplaceFile(
                        currentData: try Data(contentsOf: target),
                        currentDate: values.contentModificationDate,
                        incomingData: asset.data, incomingDate: asset.modifiedAt
                      ) else { continue }
            }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try asset.data.write(to: target, options: .atomic)
            try fileManager.setAttributes([.modificationDate: asset.modifiedAt], ofItemAtPath: target.path)
            changed = true
        }
        return changed
    }

    public static func prune(
        in directory: URL, referencedNames: Set<String>, fileManager: FileManager = .default
    ) throws {
        try requirePlainDirectory(directory.deletingLastPathComponent(), fileManager: fileManager)
        try requirePlainDirectory(directory, fileManager: fileManager)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        for url in try fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) where !referencedNames.contains(url.lastPathComponent) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try fileManager.removeItem(at: url)
        }
    }

    private static func requirePlainDirectory(_ directory: URL, fileManager: FileManager) throws {
        guard (try? fileManager.destinationOfSymbolicLink(atPath: directory.path)) == nil else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard fileManager.fileExists(atPath: directory.path) else { return }
        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
    }
}

public extension LampPresentationDeckStore {
    /// Decode every stored deck before removing any image. A damaged deck is
    /// not evidence that its images are unused, so a failed read preserves them.
    /// `keeping` names images something else still needs, such as an undo
    /// that would put back a deck showing them.
    func pruneUnreferencedAssets(keeping: Set<String> = [], fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: decksDirectoryURL.path) else { return }
        let files = try fileManager.contentsOfDirectory(
            at: decksDirectoryURL, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == LampPresentationDeckPortableLayout.deckExtension }
        var referenced = keeping
        for file in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            referenced.formUnion(try Self.decode(Data(contentsOf: file)).referencedAssetNames)
        }
        try LampPresentationAssetFiles.prune(
            in: assetsDirectoryURL, referencedNames: referenced, fileManager: fileManager
        )
    }
}

/// Which of a deck's files a device holds, where it need not hold them all.
///
/// A deck's videos and clips are large, and a phone presenting from a Mac's
/// remote, or reading a deck, has no need of them: without one, a slide
/// shows the picture's still. So on iPhone and iPad they are left on the
/// server unless downloading is turned on, for the app or for one deck.
/// Pictures always come down. Nothing here deletes anything synced: a file
/// a device does not want is only not fetched, or removed from that device.
public enum LampPresentationLargeAssets {
    /// The asset filenames among `decks` that are large: every file named as
    /// a picture's video or a clip.
    public static func largeNames(in decks: [LampPresentationDeck]) -> Set<String> {
        Set(decks.flatMap(\.slides).flatMap(\.blocks).flatMap { block in
            [block.video, block.clip?.assetPath].compactMap { $0 }
        }.filter(LampPresentationDeckValidator.isSafeAssetPath).compactMap { $0.split(separator: "/").last.map(String.init) })
    }

    /// The asset filenames a device holds for `decks`: every one they name,
    /// but a large one only where `downloadsLarge` is on, or a deck that
    /// names it is in `decksDownloadingLarge`. A file two decks share is held
    /// while either wants it.
    public static func wanted(
        decks: [LampPresentationDeck],
        downloadsLarge: Bool,
        decksDownloadingLarge: Set<String>
    ) -> Set<String> {
        decks.reduce(into: Set<String>()) { wanted, deck in
            let names = deck.referencedAssetNames
            if downloadsLarge || decksDownloadingLarge.contains(deck.id) {
                wanted.formUnion(names)
            } else {
                wanted.formUnion(names.subtracting(largeNames(in: [deck])))
            }
        }
    }

    /// Whether the asset `name` is one a device should fetch: wanted, by
    /// the same rule.
    public static func shouldFetch(
        _ name: String,
        decks: [LampPresentationDeck],
        downloadsLarge: Bool,
        decksDownloadingLarge: Set<String>
    ) -> Bool {
        wanted(decks: decks, downloadsLarge: downloadsLarge, decksDownloadingLarge: decksDownloadingLarge)
            .contains(name)
    }

    /// The large files `deck` names that this device holds, by name and size:
    /// what "Remove Downloaded Videos" would free, short of those another
    /// deck still wants.
    public static func held(
        by deck: LampPresentationDeck,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> [(name: String, bytes: Int64)] {
        largeNames(in: [deck]).sorted().compactMap { name in
            let url = directory.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true
            else { return nil }
            return (name, Int64(values.fileSize ?? 0))
        }
    }
}
