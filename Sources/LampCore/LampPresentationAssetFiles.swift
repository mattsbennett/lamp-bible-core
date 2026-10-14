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
    func pruneUnreferencedAssets(fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: decksDirectoryURL.path) else { return }
        let files = try fileManager.contentsOfDirectory(
            at: decksDirectoryURL, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == LampPresentationDeckPortableLayout.deckExtension }
        var referenced = Set<String>()
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
