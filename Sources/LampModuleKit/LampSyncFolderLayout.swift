/// What a path in the shared library holds.
///
/// Each module is its own file, and those files are the truth: the settings
/// bundle says which belong to the library, and nothing else does.
public enum LampSyncFileKind: Hashable, Sendable {
    case module(LampSyncContentKind)
    /// A file a writing embeds.
    case devotionalMedia
    /// A file one of the reader's notes embeds.
    case noteMedia
    /// An image a book shows.
    case bookMedia
    case deck
    /// An image a deck shows. Decks share one flat folder of them, under
    /// generated names.
    case deckAsset
    /// Any other file in a Mac workspace.
    case workspaceFile

    /// Media never changes at a path: a different body gets a different
    /// name. So it is never merged, uploaded only where absent, and a
    /// different copy on the server is a conflict to report.
    public var isMedia: Bool {
        switch self {
        case .devotionalMedia, .noteMedia, .bookMedia, .deckAsset: true
        case .module, .deck, .workspaceFile: false
        }
    }

    /// Whether it is part of a tree taken in together: a workspace's files
    /// are staged by `LampSyncPassLibrary.install` as they arrive and taken
    /// in by `finishInstalling`, which can stop partway. Such a file is
    /// recorded as installed only once that succeeds.
    public var isTakenInTogether: Bool {
        self == .workspaceFile
    }

    /// Whether a pass learns about it from a listing of its folder. Media and
    /// workspace files are never listed: media because the manifest names
    /// every file and a path never changes its bytes, and workspace files
    /// because they are an arbitrary tree the Mac checks one path at a time.
    public var isListed: Bool {
        switch self {
        case .module, .deck: true
        case .devotionalMedia, .noteMedia, .bookMedia, .deckAsset, .workspaceFile: false
        }
    }
}

/// Where each file lives on the server, for both WebDAV and the folder
/// provider.
///
/// | What | Path |
/// |---|---|
/// | Settings bundle | `lamp-bible.lampsync` |
/// | A module | `<Kind>/<id>.lamp`, e.g. `Translations/kjv.lamp`, `Writing/writing.lamp` |
/// | Writing media | `WritingMedia/<module>/<writing>/<file>` |
/// | Note media | `NoteMedia/<module>/<verse>/<file>` |
/// | Book images | `BookMedia/<module>/<path>` |
/// | A deck | `Workspaces/Presentations/<id>.lampdeck` |
/// | A deck image | `Workspaces/Presentations/Assets/<file>` |
/// | A Mac workspace file | `Workspaces/<path>` |
///
/// A module's bytes are the phone's: personal modules are the
/// `LampWebDAVPersonalArchiveAdapter` output, with module IDs rewritten, and a
/// `lamp-modules` build drops into its kind folder unchanged.
///
/// Until bundle format 4, writing lived under `Devotionals/` and
/// `DevotionalMedia/`, and the writing collection was
/// `Devotionals/devotionals.lamp`. `formatFourPath(ofFormatThree:)` is the
/// one statement of that rename; `LampSyncFormatFourMove` carries a library
/// across it.
public enum LampSyncFolderLayout {
    public enum PathError: Error, Equatable {
        case unsafe(String)
    }

    /// The archive's old path. Format 3 there is the bundle, which archive
    /// readers refuse, so an old client stops rather than reading a library
    /// with no modules in it as one that was emptied.
    public static let bundlePath = LampSyncLayout.archivePath
    public static let moduleExtension = "lamp"
    public static let devotionalMediaDirectory = "WritingMedia"
    public static let noteMediaDirectory = "NoteMedia"
    public static let bookMediaDirectory = "BookMedia"
    public static let workspacesDirectory = LampPortableBackupLayout.workspacesDirectory
    public static let decksDirectory = "\(workspacesDirectory)/Presentations"
    public static let deckAssetsDirectory = "\(decksDirectory)/Assets"
    public static let deckExtension = "lampdeck"

    /// The kind folders and the deck folder, one Depth:1 listing each.
    public static let listedDirectories: [String] =
        LampSyncContentKind.allCases.map(\.folder) + [decksDirectory]

    public static func modulePath(kind: LampSyncContentKind, moduleID: String) throws -> String {
        try checked([kind.folder], "\(moduleID).\(moduleExtension)")
    }

    /// Where one of the reader's notes keeps a file on the server. The owner
    /// is the verse, as it is in the library — a personal note is one per
    /// verse and its id holds a colon.
    public static func noteMediaPath(
        moduleID: String, noteOwnerID: String, filename: String
    ) throws -> String {
        try checked([noteMediaDirectory, moduleID, noteOwnerID], filename)
    }

    /// Where a notes **module**'s picture sits on the server. Keyed by the
    /// module alone, as a book's is: the module declares its pictures once
    /// and its notes point at them by id, so they are not one note's.
    public static func noteModuleMediaPath(
        moduleID: String, filename: String
    ) throws -> String {
        try checked([noteMediaDirectory, moduleID], filename)
    }

    public static func devotionalMediaPath(
        moduleID: String, devotionalID: String, filename: String
    ) throws -> String {
        try checked([devotionalMediaDirectory, moduleID, devotionalID], filename)
    }

    /// `path` is the image's path inside the book, which may have folders.
    public static func bookMediaPath(moduleID: String, path: String) throws -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let filename = components.last else { throw PathError.unsafe(path) }
        return try checked([bookMediaDirectory, moduleID] + components.dropLast(), filename)
    }

    public static func deckPath(deckID: String) throws -> String {
        try checked([decksDirectory], "\(deckID).\(deckExtension)")
    }

    public static func deckAssetPath(filename: String) throws -> String {
        try checked([deckAssetsDirectory], filename)
    }

    public static func workspaceFilePath(relativePath: String) throws -> String {
        let path = "\(workspacesDirectory)/\(relativePath)"
        guard kind(of: path) == .workspaceFile else { throw PathError.unsafe(path) }
        return path
    }

    /// What a path holds, or nil for one outside the layout: a hidden file
    /// such as an iCloud placeholder, a legacy module format, a retired
    /// alias, the bundle, or anything unsafe.
    public static func kind(of path: String) -> LampSyncFileKind? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 2, components.allSatisfy(isSafeComponent) else { return nil }
        let head = components[0]
        if components.count == 2, let kind = LampSyncContentKind(folder: head) {
            return isModuleFilename(components[1]) && !isRetiredAlias(path) ? .module(kind) : nil
        }
        if head == devotionalMediaDirectory {
            return components.count == 4 ? .devotionalMedia : nil
        }
        if head == noteMediaDirectory {
            // Four for one of the reader's own notes, keyed by its verse;
            // three for a notes module's, keyed by the module, which
            // declares its pictures once and whose notes point at them by
            // id. The count tells them apart, not the look of the segment.
            return (3...4).contains(components.count) ? .noteMedia : nil
        }
        if head == bookMediaDirectory {
            return components.count >= 3 ? .bookMedia : nil
        }
        guard head == workspacesDirectory else { return nil }
        if components[1] == "Presentations" {
            if components.count == 3 {
                return components[2].lowercased().hasSuffix(".\(deckExtension)")
                    && components[2].count > deckExtension.count + 1 ? .deck : nil
            }
            // Anything else under the deck folder belongs to the deck format.
            return components.count == 4 && components[2] == "Assets" ? .deckAsset : nil
        }
        return .workspaceFile
    }

    /// A copy the old sync left under an ID it has since renamed:
    /// `Notes/bible-notes.lamp`, merged into `notes` long ago. Outside the
    /// layout, so it is never listed, adopted or installed. Adopted, it would
    /// arrive as a second notes module holding old copies of notes, and bring
    /// back any deleted before the deletion ledger existed.
    public static func isRetiredAlias(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components[0] == Substring(LampSyncContentKind.notes.folder),
              let id = LampSyncModuleFiles.moduleID(from: String(components[1])),
              components[1].lowercased().hasSuffix(".\(moduleExtension)")
        else { return false }
        return LampSyncModuleFiles.canonicalIdentity(id, isNotes: true) != id
    }

    /// The module ID the *server* knows a module or its media by, taken from
    /// the path. It is not the ID an app uses locally: a personal module's
    /// path holds the adapter's rewritten ID (`Notes/notes.lamp` is `notes`,
    /// never the Mac's own), and a highlight module's holds the per-set ID the
    /// Mac maps it to.
    public static func remoteModuleID(of path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch kind(of: path) {
        case .module: return String(components[1].dropLast(moduleExtension.count + 1))
        case .devotionalMedia, .noteMedia, .bookMedia: return components[1]
        default: return nil
        }
    }

    // MARK: - Bundle format 3

    /// Writing's names under bundle format 3.
    public enum FormatThree {
        public static let writingFolder = "Devotionals"
        public static let writingMediaDirectory = "DevotionalMedia"
        /// The writing collection's module ID, `Devotionals/devotionals.lamp`.
        public static let writingCollectionID = "devotionals"
    }

    /// Where a path of the format-3 layout lives in format 4. A writing module
    /// moves from `Devotionals/` to `Writing/`, its media from
    /// `DevotionalMedia/` to `WritingMedia/`, and the writing collection's ID
    /// from `devotionals` to `writing`, in its file name and in its media's
    /// folder. Every other path of the format-3 layout is the same in format
    /// 4. Nil for one that layout didn't hold, `Writing/` among them.
    ///
    /// One path is left without a place: an installed writing module whose ID
    /// is already `writing` goes where the collection goes
    /// (`formatFourCollision(in:)`).
    /// (`Verification/SyncMerge.lean`: `formatFourPath`.)
    public static func formatFourPath(ofFormatThree path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 2, components.allSatisfy(isSafeComponent) else { return nil }
        let head = components[0]
        func renamed(_ id: String) -> String {
            id == FormatThree.writingCollectionID ? LampSyncLocalDeletion.writingCollectionID : id
        }
        if head == FormatThree.writingFolder {
            guard components.count == 2, isModuleFilename(components[1]),
                  let id = LampSyncModuleFiles.moduleID(from: components[1]) else { return nil }
            let renamedPath = "\(LampSyncContentKind.devotionals.folder)/\(renamed(id)).\(moduleExtension)"
            return kind(of: renamedPath) == nil ? nil : renamedPath
        }
        if head == FormatThree.writingMediaDirectory {
            guard components.count == 4 else { return nil }
            let renamedPath = ([devotionalMediaDirectory, renamed(components[1])] + components[2...])
                .joined(separator: "/")
            return kind(of: renamedPath) == nil ? nil : renamedPath
        }
        // Folders format 4 added held nothing of format 3's.
        if head == LampSyncContentKind.devotionals.folder || head == devotionalMediaDirectory { return nil }
        return kind(of: path) == nil ? nil : path
    }

    /// The format-3 paths among `paths` that would land on the same format-4
    /// path, sorted. Only the writing collection and an installed writing
    /// module with ID `writing` can: `Devotionals/devotionals.lamp` and
    /// `Devotionals/writing.lamp`, or their media folders.
    ///
    /// With the collection there, a module of any kind called `writing`
    /// collides too: the phone keeps one module per ID, whatever its kind, so
    /// its collection could not take the name. Empty for any library where
    /// the move is a renaming.
    public static func formatFourCollision(in paths: some Sequence<String>) -> [String] {
        let paths = Set(paths)
        var byTarget: [String: [String]] = [:]
        for path in paths {
            guard let target = formatFourPath(ofFormatThree: path) else { continue }
            byTarget[target, default: []].append(path)
        }
        var colliding = Set(byTarget.values.filter { $0.count > 1 }.flatMap { $0 })
        let collection = "\(FormatThree.writingFolder)/\(FormatThree.writingCollectionID).\(moduleExtension)"
        if paths.contains(collection) {
            let calledWriting = paths.filter { path in
                guard path != collection, let target = formatFourPath(ofFormatThree: path),
                      case .module? = kind(of: target) else { return false }
                return remoteModuleID(of: target) == LampSyncLocalDeletion.writingCollectionID
            }
            if !calledWriting.isEmpty { colliding.formUnion(calledWriting + [collection]) }
        }
        return colliding.sorted()
    }

    /// The format-3 path a format-4 writing path was moved from, the inverse
    /// of `formatFourPath(ofFormatThree:)`; the path itself for any other in
    /// format 4's layout, and nil for one outside it.
    public static func formatThreePath(ofFormatFour path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard kind(of: path) != nil else { return nil }
        func original(_ id: String) -> String {
            id == LampSyncLocalDeletion.writingCollectionID ? FormatThree.writingCollectionID : id
        }
        if components[0] == LampSyncContentKind.devotionals.folder,
           let id = LampSyncModuleFiles.moduleID(from: components[1]) {
            return "\(FormatThree.writingFolder)/\(original(id)).\(moduleExtension)"
        }
        if components[0] == devotionalMediaDirectory {
            return ([FormatThree.writingMediaDirectory, original(components[1])] + components[2...])
                .joined(separator: "/")
        }
        return path
    }

    private static func isModuleFilename(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".\(moduleExtension)") && name.count > moduleExtension.count + 1
    }

    /// No empty, relative or hidden component. Hidden covers iCloud's
    /// `.name.icloud` placeholders and Finder's `.DS_Store`.
    private static func isSafeComponent(_ component: String) -> Bool {
        !component.isEmpty && !component.hasPrefix(".")
            && !component.contains("\\") && !component.contains("\0")
    }

    private static func checked(_ directories: [String], _ filename: String) throws -> String {
        let path = (directories + [filename]).joined(separator: "/")
        guard kind(of: path) != nil else { throw PathError.unsafe(path) }
        return path
    }
}

extension LampSyncContentKind {
    /// The folder a module of this kind lives in.
    public init(_ kind: LampModuleKind) {
        switch kind {
        case .translation: self = .translations
        case .dictionary: self = .dictionaries
        case .commentary: self = .commentaries
        case .book: self = .books
        case .devotional: self = .devotionals
        case .notes: self = .notes
        case .plan: self = .plans
        case .highlights: self = .highlights
        case .quiz: self = .quizzes
        }
    }
}
