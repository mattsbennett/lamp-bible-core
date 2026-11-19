import Foundation

/// A writing's workspace as sync sees it: the folder it is kept in, which of
/// its files are the writer's own documents (an outline, notes, sources),
/// and where those sit on the server.
///
/// One statement for both apps. The Mac keeps a workspace for each writing it
/// has opened in its agent pane and the phone keeps the documents, and each
/// names the folder from the writing's id: two copies of the derivation would
/// not fail, they would quietly point at different folders.
///
/// A document's name is compared and written in NFC. macOS can hand back a
/// file's name decomposed, and the same name spelled two ways would be two
/// paths on the server for one file.
public enum LampWritingWorkspaceLayout {
    /// The folder under a workspace's server folder that its documents are in.
    public static let documentsFolder = "Documents"
    public static let documentExtensions: Set<String> = ["md", "markdown", "txt", "text"]
    /// Files a workspace holds that are not the writer's documents: the draft
    /// is the writing itself, which travels in its collection, and the rest
    /// are Lamp's to the agent. Compared without case.
    public static let generatedNames: Set<String> = ["agents.md", "claude.md", "devotional_context.md", "draft.md"]
    /// The longest name a kept copy is given, in UTF-8 bytes: within what
    /// every file system and server Lamp syncs through takes for a name.
    public static let maximumKeptCopyBytes = 240

    /// A folder name from a writing's id: as much of it as reads as a name,
    /// then a hash of the whole so two writings never collide.
    ///
    /// Every existing workspace on every device is named by this function, so
    /// its output is a stored format in all but name. Changing it orphans
    /// them, which is why `aKnownIdentifierKeepsItsFolderName` pins one.
    public static func directoryName(for identifier: String) -> String {
        let readable = identifier.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
                ? Character(String(scalar)) : "_"
        }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in identifier.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let prefix = String(readable.prefix(48))
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return "\(prefix.isEmpty ? "devotional" : prefix)-\(String(hash, radix: 16))"
    }

    /// Whether a file of this name, at the top of a workspace, is one of the
    /// writer's documents: Markdown or text, not one Lamp generates, and a
    /// name every file system keeps. Judged in NFC.
    public static func isDocumentName(_ name: String) -> Bool {
        let name = name.precomposedStringWithCanonicalMapping
        guard !name.isEmpty, !name.hasPrefix("."), name.utf8.count <= 255,
              !name.unicodeScalars.contains(where: { $0 == "/" || $0 == "\\" || $0 == ":"
                  || CharacterSet.controlCharacters.contains($0) })
        else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        let stem = (name as NSString).deletingPathExtension
        return documentExtensions.contains(ext) && !stem.isEmpty && !generatedNames.contains(name.lowercased())
    }

    /// `Workspaces/Writing/<folder>/Documents/<name>`, the name in NFC.
    /// Throws for a name that is not a document's.
    public static func documentPath(writingID: String, name: String) throws -> String {
        try documentPath(folder: directoryName(for: writingID), name: name)
    }

    public static func documentPath(folder: String, name: String) throws -> String {
        let name = name.precomposedStringWithCanonicalMapping
        let path = "\(LampSyncFolderLayout.writingWorkspacesDirectory)/\(folder)/\(documentsFolder)/\(name)"
        guard document(ofPath: path) != nil else { throw LampSyncFolderLayout.PathError.unsafe(path) }
        return path
    }

    /// The workspace folder and the document's name, in NFC, of a document's
    /// server path; nil for any other path.
    public static func document(ofPath path: String) -> (folder: String, name: String)? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let writing = LampSyncFolderLayout.writingWorkspacesDirectory.split(separator: "/").map(String.init)
        guard components.count == writing.count + 3,
              Array(components.prefix(writing.count)) == writing,
              components[writing.count + 1] == documentsFolder
        else { return nil }
        let folder = components[writing.count]
        let name = components[writing.count + 2].precomposedStringWithCanonicalMapping
        guard !folder.isEmpty, !folder.hasPrefix("."), !folder.contains("\\"), !folder.contains("\0"),
              isDocumentName(name) else { return nil }
        return (folder, name)
    }

    // MARK: Kept copies

    /// The name this device's edits are kept under when another device
    /// changed the same document since they last agreed:
    /// `<stem> (edits from <device>, <yyyy-MM-dd HH.mm>).<ext>`. The
    /// server's copy keeps the document's own name, since other devices may
    /// already hold it; the one that found both changed names the copy after
    /// itself, which it always knows.
    ///
    /// Always a document's name (`isDocumentName`) of at most
    /// `maximumKeptCopyBytes`: the device's name is cleaned of what a file
    /// name cannot hold, and the stem is cut to fit. `taken` says whether a
    /// name is already used here by something else, and a number is added
    /// to the time until one is free.
    public static func keptCopyName(
        of name: String, device: String, at date: Date, timeZone: TimeZone = .current,
        taken: (String) -> Bool = { _ in false }
    ) -> String {
        let name = name.precomposedStringWithCanonicalMapping
        let rawExt = (name as NSString).pathExtension
        let ext = documentExtensions.contains(rawExt.lowercased()) ? rawExt : "md"
        let stem = (name as NSString).deletingPathExtension
        let device = cleanedDeviceName(device)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let stamp = formatter.string(from: date)
        for attempt in 1... {
            let suffix = " (edits from \(device), \(stamp)\(attempt == 1 ? "" : " \(attempt)")).\(ext)"
            var cut = stem
            while !cut.isEmpty, (cut + suffix).utf8.count > maximumKeptCopyBytes { cut.removeLast() }
            cut = String(cut.drop(while: { $0 == "." || $0 == " " }))
            if cut.isEmpty { cut = "Document" }
            let candidate = cut + suffix
            if !taken(candidate) { return candidate }
        }
        fatalError("unreachable")
    }

    /// Whether a name is one `keptCopyName` makes. A kept copy is never
    /// itself copied: when two devices both change one, the server's stands.
    public static func isKeptCopy(_ name: String) -> Bool {
        let stem = (name.precomposedStringWithCanonicalMapping as NSString).deletingPathExtension
        return stem.range(
            of: #" \(edits from [^()]+, \d{4}-\d{2}-\d{2} \d{2}\.\d{2}( \d+)?\)$"#,
            options: .regularExpression
        ) != nil
    }

    /// A device's name as a kept copy holds it: in NFC, without what a file
    /// name or the copy's own pattern cannot hold, and at most 40 characters.
    static func cleanedDeviceName(_ device: String) -> String {
        let scalars = device.precomposedStringWithCanonicalMapping.unicodeScalars.map { scalar -> Character in
            "/\\:(),".unicodeScalars.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
                ? " " : Character(String(scalar))
        }
        let words = String(scalars).split(whereSeparator: { $0.isWhitespace })
        let joined = String(words.joined(separator: " ").prefix(40)).trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? "another device" : joined
    }
}

/// What a device does with a document a pass downloaded, given the copy it
/// holds. No clocks are compared: a downloaded file's date is when it
/// arrived, and devices' clocks disagree.
///
/// - nothing held, or only the server moved: take the server's;
/// - the same bytes either side: keep, nothing to do;
/// - both changed and they differ: take the server's under the document's
///   name, and keep this device's edits beside it under `keptCopyName`, so
///   every body survives. A kept copy both changed is the exception: the
///   server's stands, so copies are never made of copies.
///
/// (`Verification/SyncMerge.lean`: `documentMerge`.)
public enum LampWritingDocumentMerge {
    public enum Decision: Equatable, Sendable {
        case keep
        case take
        case takeKeepingHeldAs(String)
    }

    public static func decide(
        name: String, held: Data?, incoming: Data, bothChanged: Bool,
        localDevice: String, at date: Date, timeZone: TimeZone = .current,
        taken: (String) -> Bool = { _ in false }
    ) -> Decision {
        guard let held else { return .take }
        if held == incoming { return .keep }
        guard bothChanged, !LampWritingWorkspaceLayout.isKeptCopy(name) else { return .take }
        return .takeKeepingHeldAs(LampWritingWorkspaceLayout.keptCopyName(
            of: name, device: localDevice, at: date, timeZone: timeZone, taken: taken
        ))
    }
}
