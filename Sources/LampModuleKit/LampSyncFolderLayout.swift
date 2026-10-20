/// What a path in the shared library holds.
///
/// Each module is its own file, and those files are the truth: the settings
/// bundle says which belong to the library, and nothing else does.
public enum LampSyncFileKind: Hashable, Sendable {
    case module(LampSyncContentKind)
    /// A file a writing embeds.
    case devotionalMedia
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
        case .devotionalMedia, .bookMedia, .deckAsset: true
        case .module, .deck, .workspaceFile: false
        }
    }

    /// Whether a pass learns about it from a listing of its folder. Media and
    /// workspace files are never listed: media because the manifest names
    /// every file and a path never changes its bytes, and workspace files
    /// because they are an arbitrary tree the Mac checks one path at a time.
    public var isListed: Bool {
        switch self {
        case .module, .deck: true
        case .devotionalMedia, .bookMedia, .deckAsset, .workspaceFile: false
        }
    }
}

/// Where each file lives on the server, for both WebDAV and the folder
/// provider.
///
/// | What | Path |
/// |---|---|
/// | Settings bundle | `lamp-bible.lampsync` |
/// | A module | `<Kind>/<id>.lamp`, e.g. `Translations/kjv.lamp` |
/// | Writing media | `DevotionalMedia/<module>/<writing>/<file>` |
/// | Book images | `BookMedia/<module>/<path>` |
/// | A deck | `Workspaces/Presentations/<id>.lampdeck` |
/// | A deck image | `Workspaces/Presentations/Assets/<file>` |
/// | A Mac workspace file | `Workspaces/<path>` |
///
/// A module's bytes are the phone's: personal modules are the
/// `LampWebDAVPersonalArchiveAdapter` output, with module IDs rewritten, and a
/// `lamp-modules` build drops into its kind folder unchanged.
public enum LampSyncFolderLayout {
    public enum PathError: Error, Equatable {
        case unsafe(String)
    }

    /// The archive's old path. Format 3 there is the bundle, which archive
    /// readers refuse, so an old client stops rather than reading a library
    /// with no modules in it as one that was emptied.
    public static let bundlePath = LampSyncLayout.archivePath
    public static let moduleExtension = "lamp"
    public static let devotionalMediaDirectory = "DevotionalMedia"
    public static let bookMediaDirectory = "BookMedia"
    public static let workspacesDirectory = LampPortableBackupLayout.workspacesDirectory
    public static let decksDirectory = "\(workspacesDirectory)/Presentations"
    public static let deckAssetsDirectory = "\(decksDirectory)/Assets"
    public static let deckExtension = "lampdeck"

    /// The kind folders and the deck folder, one Depth:1 listing each.
    public static let listedDirectories: [String] =
        LampSyncContentKind.allCases.map(\.rawValue) + [decksDirectory]

    public static func modulePath(kind: LampSyncContentKind, moduleID: String) throws -> String {
        try checked([kind.rawValue], "\(moduleID).\(moduleExtension)")
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
    /// such as an iCloud placeholder, a legacy module format, the bundle, or
    /// anything unsafe.
    public static func kind(of path: String) -> LampSyncFileKind? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 2, components.allSatisfy(isSafeComponent) else { return nil }
        let head = components[0]
        if components.count == 2, let kind = LampSyncContentKind(rawValue: head) {
            return isModuleFilename(components[1]) ? .module(kind) : nil
        }
        if head == devotionalMediaDirectory {
            return components.count == 4 ? .devotionalMedia : nil
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

    /// The module ID the *server* knows a module or its media by, taken from
    /// the path. It is not the ID an app uses locally: a personal module's
    /// path holds the adapter's rewritten ID (`Notes/notes.lamp` is `notes`,
    /// never the Mac's own), and a highlight module's holds the per-set ID the
    /// Mac maps it to.
    public static func remoteModuleID(of path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch kind(of: path) {
        case .module: return String(components[1].dropLast(moduleExtension.count + 1))
        case .devotionalMedia, .bookMedia: return components[1]
        default: return nil
        }
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
