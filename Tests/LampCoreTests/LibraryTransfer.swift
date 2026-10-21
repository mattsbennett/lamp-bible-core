import Foundation
import LampModuleKit
@testable import LampCore

/// What one library took in from another's export.
struct Received: Equatable {
    var studyEntries = 0
    var devotionals = 0
}

extension LampLibrary {
    /// Takes in another library's export, `exportPortableBackup`'s folder,
    /// as a sync does when that content arrives: the deletion record first,
    /// so content deleted there is skipped; then modules, notes and
    /// highlights, writing and media; then the deletions, applied. Tests move
    /// content between two libraries with this, through the library's own
    /// import functions.
    @discardableResult
    func receive(exportAt url: URL) throws -> Received {
        let fileManager = FileManager.default
        let ledger = url.appendingPathComponent(LampPortableBackupLayout.deletionLedgerPath)
        if fileManager.fileExists(atPath: ledger.path) {
            try mergePersonalDeletionLedger(LampPersonalDeletionLedger.decode(Data(contentsOf: ledger)))
        }
        func files(in directory: String, _ fileExtension: String) -> [URL] {
            let root = url.appendingPathComponent(directory, isDirectory: true)
            let found = fileManager.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            return (found?.compactMap { $0 as? URL } ?? [])
                .filter { $0.pathExtension.lowercased() == fileExtension }
                .sorted { $0.path < $1.path }
        }
        var received = Received()
        for module in files(in: LampPortableBackupLayout.modulesDirectory, "lamp") {
            _ = try install(from: module)
        }
        for study in files(in: LampPortableBackupLayout.studyDirectory, "json") {
            received.studyEntries += try importPersonalStudyData(from: study, forSync: true).importedCount
        }
        for writing in files(in: LampPortableBackupLayout.devotionalsDirectory, "json") {
            received.devotionals += try importPersonalDevotional(from: writing, forSync: true).count
        }
        let media = url.appendingPathComponent(LampPortableBackupLayout.mediaDirectory, isDirectory: true)
        for file in files(in: LampPortableBackupLayout.mediaDirectory, "")
            + (fileManager.enumerator(at: media, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
        where !file.hasDirectoryPath {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue
            else { continue }
            let relative = String(file.standardizedFileURL.path.dropFirst(media.standardizedFileURL.path.count + 1))
            let target = rootURL.appendingPathComponent(LampPortableBackupLayout.mediaDirectory)
                .appendingPathComponent(relative)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
            try fileManager.copyItem(at: file, to: target)
        }
        try applyPersonalDeletionLedger()
        return received
    }
}
