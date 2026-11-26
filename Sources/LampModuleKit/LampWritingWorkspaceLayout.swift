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

    /// The writing a workspace folder belongs to, among the ids given.
    ///
    /// A folder's name is its writing's id made safe and shortened with a
    /// digest of the id after it, so it cannot be read back: the ids are
    /// asked instead, and the one whose id makes this name is it. Both
    /// apps needed this and each asked a different place for the ids.
    public static func writingID(ofFolder folder: String, among ids: some Sequence<String>) -> String? {
        ids.first { directoryName(for: $0) == folder }
    }

    /// Whether a file of this name, at the top of a workspace, is one of the
    /// writer's documents: Markdown or text, not one Lamp generates, and a
    /// name every file system keeps. Judged in NFC.
    public static func isDocumentName(_ name: String) -> Bool {
        let name = name.precomposedStringWithCanonicalMapping
        // By scalar: a period with a combining mark after it is one
        // Character that does not begin with ".", but the file is hidden.
        guard !name.isEmpty, name.unicodeScalars.first != ".", name.utf8.count <= 255,
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
        guard !folder.isEmpty, folder.unicodeScalars.first != ".", !folder.contains("\\"), !folder.contains("\0"),
              isDocumentName(name) else { return nil }
        return (folder, name)
    }

    /// The folder a writing's sources are published under.
    public static let contextFolder = "Context"

    /// Folders that hold a tool's output rather than the writer's sources:
    /// installed packages, virtual environments, caches, a repository's
    /// history. Reproducible by the tool, and often thousands of files — on
    /// the owner's library one `node_modules` was 489 of 842 synced files.
    /// Nothing under one is a source: it is not published, and a copy
    /// already on the server is removed from it (`decisions/0023`). Matched
    /// by exact name, as the tools write them.
    public static let toolFolders: Set<String> = [
        "node_modules", "venv", ".venv", "__pycache__", ".git",
    ]

    /// Whether a path under `Context/` lies inside a tool's folder: any of
    /// its folders is one. The file's own name is not looked at — a source
    /// called `venv` is still a source.
    public static func isToolOutput(relativePath: String) -> Bool {
        relativePath.split(separator: "/").dropLast().contains { toolFolders.contains(String($0)) }
    }

    /// Where one of a writing's sources is published:
    /// `Workspaces/Writing/<folder>/Context/<relativePath>`.
    public static func contextPath(folder: String, relativePath: String) throws -> String {
        let path = [
            LampSyncFolderLayout.writingWorkspacesDirectory, folder, contextFolder, relativePath,
        ].joined(separator: "/")
        guard contextFile(ofPath: path) != nil else {
            throw LampSyncFolderLayout.PathError.unsafe(relativePath)
        }
        return path
    }

    /// One of a writing's **sources**, by its workspace folder and its
    /// relative path inside `Context/`.
    ///
    /// Nested names are allowed, unlike a document's: a reader's sources come
    /// in folders. In NFC for the same reason document names are — two
    /// devices spell the same filename differently and must agree it is one
    /// file.
    public static func contextFile(ofPath path: String) -> (folder: String, relativePath: String)? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let writing = LampSyncFolderLayout.writingWorkspacesDirectory.split(separator: "/").map(String.init)
        guard components.count >= writing.count + 3,
              Array(components.prefix(writing.count)) == writing,
              components[writing.count + 1] == contextFolder
        else { return nil }
        let folder = components[writing.count]
        let rest = Array(components[(writing.count + 2)...])
        guard !folder.isEmpty, folder.unicodeScalars.first != ".",
              !folder.contains("\\"), !folder.contains("\u{0}"),
              !rest.isEmpty,
              !rest.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { return nil }
        return (folder, rest.joined(separator: "/").precomposedStringWithCanonicalMapping)
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
            while let first = cut.unicodeScalars.first, first == "." || first == " " { cut.removeFirst() }
            if cut.isEmpty { cut = "Document" }
            let candidate = cut + suffix
            if !taken(candidate) { return candidate }
        }
        fatalError("unreachable")
    }

    /// Whether a name is one `keptCopyName` makes, as both apps show a kept
    /// copy. A copy both sides changed is kept again like any document, its
    /// name taking a second suffix: no clocks are compared, so nothing makes
    /// copies of its own accord.
    public static func isKeptCopy(_ name: String) -> Bool {
        let stem = (name.precomposedStringWithCanonicalMapping as NSString).deletingPathExtension
        return stem.range(
            of: #" \(edits from [^()]+, \d{4}-\d{2}-\d{2} \d{2}\.\d{2}( \d+)?\)$"#,
            options: .regularExpression
        ) != nil
    }

    /// A device's name as a kept copy holds it: in NFC, without what a file
    /// name or the copy's own pattern cannot hold, and at most 60 bytes,
    /// cut between characters.
    static func cleanedDeviceName(_ device: String) -> String {
        let scalars = device.precomposedStringWithCanonicalMapping.unicodeScalars.map { scalar -> Character in
            "/\\:(),".unicodeScalars.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
                ? " " : Character(String(scalar))
        }
        let words = String(scalars).split(whereSeparator: { $0.isWhitespace })
        var joined = words.joined(separator: " ")
        while joined.utf8.count > 60 { joined.removeLast() }
        joined = joined.trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? "another device" : joined
    }
}

/// What a device does with a document a pass downloaded, given the copy it
/// holds and what it last agreed with the server on (`agreedDigest`, the
/// digest of the bytes it last sent or took, nil for never). No clocks are
/// compared: a downloaded file's date is when it arrived, and devices'
/// clocks disagree. Nor is the plan's word that both sides changed taken:
/// a save can land between the plan and the install, so what this device
/// holds is judged as it stands, under the file's lock.
///
/// - nothing held: take the server's;
/// - the same bytes either side: keep, nothing to do;
/// - held as last agreed, so only the server moved: take the server's;
/// - otherwise both changed: take the server's under the document's name,
///   and keep this device's edits beside it under `keptCopyName`, so every
///   body survives.
///
/// (`Verification/SyncMerge.lean`: `documentMerge`.)
public enum LampWritingDocumentMerge {
    public enum Decision: Equatable, Sendable {
        case keep
        case take
        case takeKeepingHeldAs(String)
    }

    public static func decide(
        name: String, held: Data?, incoming: Data, agreedDigest: String?,
        localDevice: String, at date: Date, timeZone: TimeZone = .current,
        taken: (String) -> Bool = { _ in false }
    ) -> Decision {
        guard let held else { return .take }
        if held == incoming { return .keep }
        if LampSyncContentRevision.digest(for: held) == agreedDigest { return .take }
        return .takeKeepingHeldAs(LampWritingWorkspaceLayout.keptCopyName(
            of: name, device: localDevice, at: date, timeZone: timeZone, taken: taken
        ))
    }

    /// Whether a document deleted on another device is kept here as a copy
    /// rather than removed: where this device edited it since it last
    /// agreed with the server. A deletion takes the document away, never an
    /// edit the deleting device did not see.
    /// (`Verification/SyncMerge.lean`: `documentDeletionKeeps`.)
    public static func keepsOnDeletion(held: Data?, agreedDigest: String?) -> Bool {
        guard let held else { return false }
        return LampSyncContentRevision.digest(for: held) != agreedDigest
    }
}
